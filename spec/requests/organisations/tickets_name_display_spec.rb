# frozen_string_literal: true

require 'rails_helper'

# Slack model since 05.09.2026 (user decision): the avatar chip shows ALWAYS
# at the ticket assignee spots — picture where one is uploaded, initials where
# not — and the name-display setting only picks the SPELLING of the name next
# to it. Grew out of two post-deploy reports (04.09.2026: first the circle
# mode changed nothing here, then circle-alone hid the name).
#
# Adaptive density since 08.09.2026 (user decision): the name shows while ONE
# person is assigned, several people render as chips only, the viewer first
# and the rest alphabetically. The rule itself is pinned in
# spec/helpers/application_helper_spec.rb; here it is pinned on the two
# surfaces it was written for, the ticket list and the detail head.
RSpec.describe 'Ticket assignee name display', type: :request do
  let(:organisation) { create(:organisation) }
  let(:viewer) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: viewer, organisation: organisation, role: role, active: true)
    end
  end

  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  let(:with_avatar) { create(:user, first_name: 'Guido', last_name: 'Boyke') }
  let(:without_avatar) { create(:user, first_name: 'Erika', last_name: 'Musterfrau') }

  let!(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, assignees: [with_avatar, without_avatar])
    end
  end

  # ONE person assigned: the adaptive density shows the name here and hides
  # it on `ticket`, where two people are assigned.
  let!(:solo_ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, assignees: [with_avatar])
    end
  end

  before do
    Prosopite.pause
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission, user: viewer, project: project, tickets_access: 'read_write')
    end
    with_avatar.avatar.attach(io: Rails.root.join('spec/fixtures/files/test_avatar.png').open,
                              filename: 'avatar.png', content_type: 'image/png')
    with_avatar.save!
    sign_in viewer
    ActsAsTenant.current_tenant = organisation
    Prosopite.resume
  end

  def body_page
    Capybara.string(response.body)
  end

  # The head's assignee spot: a button for a writer (the people menu since
  # 09.09.2026), a span for a reader; the marker is the same on both.
  def assignee_row
    body_page.find('[data-assignee-spot]')
  end

  def assignee_cell(list_ticket)
    body_page.find(%(tr[data-ticket-id="#{list_ticket.id}"] td.assignees-column))
  end

  context 'with the default (full) mode' do
    it 'renders chip + full name on the detail page while ONE person is assigned (the picture where uploaded)' do
      get organisation_project_ticket_path(organisation, project, solo_ticket)

      expect(response).to have_http_status(:ok)
      expect(assignee_row).to have_css('span.neo-user-avatar[title="Guido Boyke"] img')
      expect(assignee_row).to have_text('Guido Boyke')
    end

    it 'renders chips WITHOUT names on the detail page once two people are assigned: the picture where uploaded, initials where not' do
      get organisation_project_ticket_path(organisation, project, ticket)

      expect(response).to have_http_status(:ok)
      expect(assignee_row).to have_css('span.neo-user-avatar[title="Guido Boyke"] img')
      expect(assignee_row).to have_css('span.neo-user-avatar[title="Erika Musterfrau"]', text: 'EM')
      expect(assignee_row).to have_no_text('Guido Boyke')
      expect(assignee_row).to have_no_text('Erika Musterfrau')
    end

    it 'dropped the person icon from the assignee spot (the chip replaced it)' do
      get organisation_project_ticket_path(organisation, project, ticket)

      expect(body_page).to have_css('[data-assignee-spot]')
      expect(body_page).to have_no_css('[data-assignee-spot] i.bi-person-fill')
    end

    it 'renders the assignee column adaptively: chip + name for one person, chips only for two' do
      get organisation_project_tickets_path(organisation, project)

      expect(response).to have_http_status(:ok)
      expect(assignee_cell(solo_ticket)).to have_css('span.neo-user-avatar[title="Guido Boyke"] img')
      expect(assignee_cell(solo_ticket)).to have_text('Guido Boyke')

      expect(assignee_cell(ticket)).to have_css('span.neo-user-avatar[title="Guido Boyke"] img')
      expect(assignee_cell(ticket)).to have_css('span.neo-user-avatar[title="Erika Musterfrau"]', text: 'EM')
      expect(assignee_cell(ticket)).to have_no_text('Guido Boyke')
      expect(assignee_cell(ticket)).to have_no_text('Erika Musterfrau')
    end

    # The viewer reads themselves first; the rest follows the displayed name.
    # Mara Zinn is last alphabetically and first here, in the list and in the
    # detail head alike (one seam, viewer_ordered_users).
    it 'puts the viewer first among the assignees, then the rest alphabetically' do
      viewer.update!(first_name: 'Mara', last_name: 'Zinn')
      ActsAsTenant.with_tenant(organisation) do
        ticket.assignees << viewer
      end

      get organisation_project_tickets_path(organisation, project)
      list_titles = assignee_cell(ticket).all('span.neo-user-avatar').map { |chip| chip[:title] }
      expect(list_titles).to eq(['Mara Zinn', 'Erika Musterfrau', 'Guido Boyke'])

      get organisation_project_ticket_path(organisation, project, ticket)
      detail_titles = assignee_row.all('span.neo-user-avatar').map { |chip| chip[:title] }
      expect(detail_titles).to eq(['Mara Zinn', 'Erika Musterfrau', 'Guido Boyke'])
    end

    # Production, 07.09.2026: every chip of the same picture carried its own
    # signed address (the expiry stamped to the millisecond of the render), so
    # a list of tickets assigned to one person fired one Rails request per row,
    # 53 to 59 per load, and Rack::Attack's requests/ip budget answered the list
    # itself with 429. The component rounds the expiry to a slot
    # (avatar_component_spec pins the slot rule); THIS example pins the symptom
    # where it was seen: one picture, one address, however many rows show it.
    #
    # Real time on purpose. With the clock frozen every row renders at one
    # instant and even the UNFIXED component produced one address: a first cut
    # of this example with freeze_time stayed green against the bug it was
    # written for (08.09.2026). The rows must render at different milliseconds,
    # as they do in production. The one thing to keep out of the request is a
    # slot boundary; it is stepped over when it is closer than two seconds.
    it 'gives the same picture ONE address across every row it appears in (the 429 of 07.09.2026)' do
      # Paused like the before block: three ticket creations load the
      # organisation three times, which Prosopite reads as an N+1 of the SETUP.
      # The request below runs scanned, so a real N+1 in the four-row list
      # (the avatar blobs are preloaded, tickets_controller
      # optimized_ticket_includes) would still go red here.
      Prosopite.pause
      ActsAsTenant.with_tenant(organisation) do
        create_list(:ticket, 3, project: project, assignees: [with_avatar])
      end
      Prosopite.resume

      slot = ActiveStorage.urls_expire_in.to_i
      sleep 2 if slot.positive? && (slot - (Time.now.to_i % slot)) < 2
      get organisation_project_tickets_path(organisation, project)

      sources = body_page.all('span.neo-user-avatar[title="Guido Boyke"] img').map { |img| img[:src] }
      expect(sources.size).to be >= 4
      expect(sources.uniq.size).to eq(1)
    end

    it 'renders the notified line with names and the in-place checkbox editor (mockup 05.09.2026)' do
      # The assignment callbacks already auto-subscribed both assignees, so
      # the "Benachrichtigt" section is on the page without further setup.
      # Collapsed: one TEXT line naming the subscribers in the viewer's
      # spelling plus the "aendern" swap; the editor (hidden until opened)
      # carries chip rows with checkboxes - no modal, no navigation.
      get organisation_project_ticket_path(organisation, project, ticket)

      section = body_page.find('[data-controller~="subscriber-picker"]')
      summary = section.find('[data-subscriber-picker-target="summary"]')
      expect(summary).to have_text(I18n.t('views.shared.subscriber_list.label'))
      expect(summary).to have_text('Erika Musterfrau')
      expect(summary).to have_button(I18n.t('views.shared.subscriber_list.change'))

      editor = section.find('[data-subscriber-picker-target="editor"]')
      expect(editor).to have_css('span.neo-user-avatar[title="Erika Musterfrau"]', text: 'EM')
      expect(editor).to have_button(I18n.t('views.shared.subscriber_list.done'))
      # Every row submits immediately and keeps the editor open across the
      # Turbo replace.
      expect(editor).to have_css('input[name="subscriber_open"]', visible: :all)
    end

    it 'keeps the checkbox editor open across a toggle (subscriber_open param)' do
      post toggle_organisation_project_ticket_subscription_path(
        organisation_id: organisation.id, project_id: project.id, ticket_id: ticket.id
      ), params: { subscriber_open: 1 }, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      # The replace arrives inside <turbo-stream><template> - Capybara does
      # not descend into template content, so parse it out first.
      template = Nokogiri::HTML5.fragment(response.body).at_css('turbo-stream template')
      replaced = Nokogiri::HTML5.fragment(template.inner_html)
      expect(replaced.at_css('[data-subscriber-picker-target="editor"]')[:class]).not_to include('hidden')
      expect(replaced.at_css('[data-subscriber-picker-target="summary"]')[:class]).to include('hidden')
    end

    # On the solo ticket on purpose: with two people the default mode shows
    # chips only as well, so only ONE person tells the two modes apart.
    it "renders chips WITHOUT names even for one person when the view config says 'initials' (density switch, user feedback 05.09.)" do
      ActsAsTenant.with_tenant(organisation) do
        config = ViewConfiguration.for_user_project(viewer, project, 'tickets')
        config.update!(detail_settings: config.detail_settings.merge('assignee_display' => 'initials'))
      end

      get organisation_project_ticket_path(organisation, project, solo_ticket)

      expect(assignee_row).to have_css('span.neo-user-avatar[title="Guido Boyke"] img')
      expect(assignee_row).to have_no_text('Guido Boyke')
    end
  end

  context 'when the viewer chose an abbreviated spelling' do
    before { viewer.update!(preferences: { 'name_display' => 'first_last_initial' }) }

    it 'keeps the chip and spells the name next to it while one person is assigned' do
      get organisation_project_ticket_path(organisation, project, solo_ticket)

      expect(assignee_row).to have_css('span.neo-user-avatar[title="Guido Boyke"] img')
      expect(assignee_row).to have_text('Guido B.')
    end
  end

  # The Verlauf left the name-display setting behind on 05.09.2026 and then
  # became Slack-shaped: mark AND bold name in the viewer's spelling. This
  # pins the pair; what the mark itself looks like is pinned in
  # spec/requests/organisations/tickets_timeline_row_spec.rb.
  it 'renders the comment author as mark plus spelled name in the timeline' do
    viewer.update!(preferences: { 'name_display' => 'first_last_initial' })
    post_record = ActsAsTenant.with_tenant(organisation) do
      create(:post, ticket: ticket, user: without_avatar, organisation: organisation)
    end

    # The Verlauf loads through its own lazy turbo frame, not the plain show.
    get timeline_organisation_project_ticket_path(organisation, project, ticket)

    row = body_page.find("#post_#{post_record.id}")
    expect(row).to have_css('span[title="Erika Musterfrau"]', text: 'EM')
    expect(row).to have_css('span[title="Erika Musterfrau"]', text: 'Erika M.')
    expect(row).to have_no_text('Erika Musterfrau')
  end

  # Slack's grouping rule (user mockup 05.09.2026): a comment DIRECTLY after
  # another comment by the same person carries no head - no chip, no name,
  # just the text on the shared edge with its always-visible time. A different
  # author restores the head. Works because the timeline filters the redundant
  # post_added activities out (TicketTimelineService), so consecutive comments
  # really are adjacent.
  it 'collapses the head of a follow-up comment by the same person' do
    first, follow_up, other_author = ActsAsTenant.with_tenant(organisation) do
      [create(:post, ticket: ticket, user: without_avatar, organisation: organisation),
       create(:post, ticket: ticket, user: without_avatar, organisation: organisation),
       create(:post, ticket: ticket, user: with_avatar, organisation: organisation)]
    end

    get timeline_organisation_project_ticket_path(organisation, project, ticket)

    expect(body_page.find("#post_#{first.id}")).to have_css('.neo-user-avatar')
    expect(body_page.find("#post_#{follow_up.id}")).to have_no_css('.neo-user-avatar')
    expect(body_page.find("#post_#{follow_up.id}")).to have_css('time')
    expect(body_page.find("#post_#{other_author.id}")).to have_css('.neo-user-avatar')

    # The spacing says the same thing (mockup 05.09.2026): 6px inside a block
    # of the same person, 20px between blocks - on the timeline wrappers.
    expect(response.body).to include('data-timeline-filter-target="post" class="mt-1.5"')
    expect(response.body).to include('data-timeline-filter-target="post" class="mt-5"')
  end
end
