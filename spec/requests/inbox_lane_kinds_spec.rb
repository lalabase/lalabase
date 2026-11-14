# frozen_string_literal: true

require 'rails_helper'

# What: the lane of an organisation's inbox for a row that is not about a ticket. A row about
#       a project reports one of its events, and Inbox::LaneKind says what the lane shows for
#       it: a note in a nested frame drawn by the note's own controller, a card for an event
#       without a display (a new member) or with a deleted object, and the old notice for a
#       subject the lane does not know.
# Why:  until S4 every such row left the page for the project, whatever it was about. The
#       lane now shows what belongs to another area, so this file pins who decides: the row is
#       there by the rule of the notifications (the area of the EVENT), the object by its own
#       policy, asked before anything of it is drawn; the inbox renders nothing of a note
#       itself. Also pinned: "what was new" names every event of a project row and none of an
#       area the person may not read, and the head of an open note or card row gets its new
#       buttons like a ticket's. Plan: cross_org_inbox_s4_plan.md §5.
RSpec.describe 'The lane of the inbox for the kinds of things', :ci_guard, type: :request do
  before { Prosopite.pause } # pre-existing N+1 in the render path
  after  { Prosopite.resume }

  let(:organisation) { create(:organisation, name: 'Nord GmbH') }
  let(:user) { create(:user, first_name: 'Lea', last_name: 'Leser') }
  let(:colleague) { create(:user, first_name: 'Kai', last_name: 'Kollege') }
  let(:role) { create(:admin_role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Portal') } }
  let(:note) do
    ActsAsTenant.with_tenant(organisation) do
      create(:note, project: project, organisation: organisation, creator: colleague, title: 'Protokoll Kickoff')
    end
  end
  let(:frame) { { 'Turbo-Frame' => 'ticket_pane' } }

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
  end

  after { ActsAsTenant.current_tenant = nil }

  def event_row(action, **options)
    project_event_row(organisation, project, action, recipient: user, actor: colleague, **options)
  end

  def note_row(**options)
    event_row('note_created', secondary: note, parameters: { 'note_title' => note.title }, **options)
  end

  def lane(notification, **query)
    get organisation_notifications_path(organisation, state_filters: %w[read unread], notification: notification.id, **query),
        headers: frame
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def words(key)
    I18n.t("views.organisations.notifications.actions.#{key}")
  end

  def note_page
    organisation_project_note_path(organisation, project, note)
  end

  describe 'a row about a new note' do
    let!(:row) { note_row }

    it 'answers the chrome of the lane and a frame that loads the note from its own controller' do
      pane = lane(row).at_css('turbo-frame#ticket_pane')

      expect(response.body).not_to include('<html', 'id="inbox_master_list"')
      # The chrome: the project, the actions on the notification, the way out, the read timer.
      expect(pane.at_css('.inbox-lane-head__project').text).to eq('Portal')
      expect(pane.css('#inbox_pane_status_pills button').map { |button| button.text.squish })
        .to eq([words(:mark_read), words(:archive)])
      expect(pane.css('[data-lane-close]').size).to eq(1)
      timer = pane.at_css('[data-controller="pane-mark-read-delay"]')
      expect(timer['data-pane-mark-read-delay-url-value']).to eq(mark_read_organisation_notification_path(organisation, row))

      # The body: one frame with the note's own frame address, and nothing of the note itself.
      inner = pane.at_css('turbo-frame#ticket_display_frame')
      path, query = inner['src'].split('?')
      expect(path).to eq(note_page)
      expect(Rack::Utils.parse_query(query)).to eq('frame' => 'content', 'frame_id' => 'ticket_display_frame')
      expect(inner.children.text.strip).to eq('')
      expect(pane.at_css('.note-content')).to be_nil
      expect(pane.at_css('[data-inbox-event-card]')).to be_nil
    end

    it 'links the head to the page of the note, in its own words' do
      link = lane(row).at_css('#inbox_pane_status_pills a.inbox-lane-actions__open')

      expect(link['href']).to eq(note_page)
      expect(link['target']).to eq('_top')
      expect(link.text.squish).to eq(I18n.t('views.organisations.notifications.pane.open_full_view_of.note'))
    end

    it 'draws no read timer for a row that is read' do
      row.update!(state: :read, read_at: Time.current)
      pane = lane(row).at_css('turbo-frame#ticket_pane')

      expect(pane.at_css('turbo-frame#ticket_display_frame')).to be_present
      expect(pane.at_css('[data-controller="pane-mark-read-delay"]')).to be_nil
    end

    it 'marks the open row in the list and keeps its title' do
      stream = lane(row).at_css("turbo-stream[action='replace'][target='notification_#{row.id}']")
      redrawn = Nokogiri::HTML.fragment(stream.at_css('template').inner_html)

      expect(redrawn.at_css('.inbox-row')['class']).to include('selected-row')
      expect(redrawn.at_css('.inbox-row__title').text).to eq('Protokoll Kickoff')
    end

    it 'keeps the project as the title of the open row when the row is a bundle in the list' do
      event_row('member_added', parameters: { 'user_name' => 'Kai Kollege' }, created_at: 2.hours.ago)
      stream = lane(row).at_css("turbo-stream[action='replace'][target='notification_#{row.id}']")
      redrawn = Nokogiri::HTML.fragment(stream.at_css('template').inner_html)

      expect(redrawn.at_css('.inbox-row__title').text).to eq('Portal')
    end

    it 'answers the unauthorized pane when the policy of the note refuses, in the words of a note' do
      # No real state reaches this: the row is visible by the notes area of the note's
      # project, which is what NotePolicy#show? asks too. The refusal is therefore stubbed at
      # the policy, and the example proves the loader asks it before anything is drawn.
      expect(lane(row).at_css('turbo-frame#ticket_display_frame')).to be_present
      allow_any_instance_of(NotePolicy).to receive(:show?).and_return(false)

      pane = lane(row).at_css('turbo-frame#ticket_pane')

      expect(controller.instance_variable_get(:@pane_state)).to eq(:unauthorized)
      expect(pane.at_css('.inbox-lane-notice__title').text)
        .to eq(I18n.t('views.organisations.notifications.pane.unauthorized_title_of.note'))
      expect(pane.at_css('turbo-frame#ticket_display_frame')).to be_nil
      expect(response.body).not_to include(note_page)
    end

    it 'answers the gone card and no frame once the note is deleted' do
      expect(lane(row).at_css('turbo-frame#ticket_display_frame')).to be_present
      ActsAsTenant.with_tenant(organisation) { note.destroy! }

      pane = lane(row).at_css('turbo-frame#ticket_pane')

      card = pane.at_css('[data-inbox-event-card="gone"]')
      expect(card.at_css('.inbox-lane-notice__title').text).to eq(I18n.t('views.organisations.notifications.pane.event_card.gone.title'))
      expect(card.at_css('.inbox-lane-notice__body').text).to include('Kai Kollege', 'Protokoll Kickoff')
      expect(card.css('a').map { |a| a['href'] }).to eq([organisation_project_path(organisation, project)])
      expect(pane.at_css('turbo-frame#ticket_display_frame')).to be_nil
      # The chrome stays: the row can still be read and archived.
      expect(pane.css('#inbox_pane_status_pills button').size).to eq(2)
      expect(pane.at_css('#inbox_pane_status_pills a')).to be_nil
    end

    it 'answers the gone card when the activity of the event is gone (retention)' do
      lost = event_row('note_created', parameters: { 'note_title' => 'Altes Protokoll' }, activity: false)

      pane = lane(lost).at_css('turbo-frame#ticket_pane')

      expect(pane.at_css('[data-inbox-event-card="gone"]')).to be_present
      expect(pane.at_css('turbo-frame#ticket_display_frame')).to be_nil
    end
  end

  describe 'a row about a new member' do
    let!(:row) { event_row('member_added', parameters: { 'user_name' => 'Mia Neu' }) }

    it 'answers the card: who did what, the name from the payload and one link' do
      pane = lane(row).at_css('turbo-frame#ticket_pane')

      card = pane.at_css('[data-inbox-event-card="member_added"]')
      expect(card.at_css('.inbox-lane-notice__title').text).to eq(I18n.t('views.organisations.notifications.pane.event_card.member_added.title'))
      body = card.at_css('.inbox-lane-notice__body').text
      expect(body).to include("Kai Kollege #{I18n.t('views.organisations.notifications.pane.event_card.member_added.what')}", 'Mia Neu')
      expect(card.css('a').map { |a| [a['href'], a['target']] }).to eq([[organisation_project_path(organisation, project), '_top']])

      # In the chrome of the lane, with the actions on the notification and no link of the head.
      expect(pane.at_css('.inbox-lane-head__project').text).to eq('Portal')
      expect(pane.css('#inbox_pane_status_pills button').map { |button| button.text.squish })
        .to eq([words(:mark_read), words(:archive)])
      expect(pane.at_css('#inbox_pane_status_pills a')).to be_nil
      expect(pane.at_css('turbo-frame#ticket_display_frame')).to be_nil
      expect(pane.at_css('[data-controller="pane-mark-read-delay"]')).to be_present
    end

    it 'gives an event nobody has worded the default card, with the project in its title' do
      bulk = event_row('tickets_bulk_changed', parameters: { 'count' => 3 }, event_type: 'tickets_bulk_changed')

      card = lane(bulk).at_css('[data-inbox-event-card="default"]')

      expect(card.at_css('.inbox-lane-notice__title').text)
        .to eq(I18n.t('views.organisations.notifications.pane.event_card.default.title', project: 'Portal'))
      expect(card.css('a').map { |a| a['href'] }).to eq([organisation_project_path(organisation, project)])
    end

    it 'links the card of a new meeting to the meeting, which has no display in the lane yet' do
      meeting = ActsAsTenant.with_tenant(organisation) { create(:meeting, project: project, organisation: organisation, title: 'Kickoff') }
      row = event_row('meeting_created', secondary: meeting, parameters: { 'meeting_title' => 'Kickoff' })

      card = lane(row).at_css('[data-inbox-event-card="meeting_created"]')

      expect(card.at_css('.inbox-lane-notice__body').text).to include('Kickoff')
      expect(card.css('a').map { |a| [a['href'], a.text.squish] })
        .to eq([[organisation_project_meeting_path(organisation, project, meeting),
                 I18n.t('views.organisations.notifications.pane.event_card.links.meeting')]])
    end
  end

  describe 'a row about a subject without an entry' do
    it 'answers the notice with the link to the full view, as before' do
      person = ActsAsTenant.with_tenant(organisation) { create(:person, organisation: organisation) }
      row = ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation, notifiable: person, channel: 'in_app', state: :delivered)
      end

      pane = lane(row).at_css('turbo-frame#ticket_pane')

      expect(controller.instance_variable_get(:@pane_state)).to eq(:non_ticket)
      expect(pane.at_css('.inbox-lane-notice__title').text).to eq(I18n.t('views.organisations.notifications.pane.non_ticket_title'))
      expect(pane.at_css('a.inbox-lane-notice__link')['href']).to start_with(open_organisation_notification_path(organisation, row))
      expect(pane.at_css('#inbox_pane_status_pills')).to be_nil
      expect(pane.at_css('turbo-frame#ticket_display_frame')).to be_nil
    end
  end

  # Every entry of the registry that promises a display has the road for it: the object's own
  # controller answers its frame address with the frame the lane holds. The example walks the
  # registry, so an entry without that road is red.
  describe 'the registry against the controllers' do
    let(:objects) do
      { Note => note }
    end

    it 'has an object of this spec for every entry with a display' do
      displays = Inbox::LaneKind::REGISTRY.select { |_klass, entry| entry.body == :frame }.keys

      expect(displays).not_to be_empty
      expect(displays - objects.keys).to eq([])
    end

    Inbox::LaneKind::REGISTRY.select { |_klass, entry| entry.body == :frame }.each_key do |klass|
      it "answers the frame of a #{klass.name} with the id the lane holds and the object's title" do
        object = objects.fetch(klass)
        address = Inbox::ObjectFrame.path(object, organisation: organisation.id, project: project.id)

        get address, headers: { 'Turbo-Frame' => 'ticket_display_frame' }

        expect(response).to have_http_status(:ok)
        answer = Nokogiri::HTML(response.body)
        expect(answer.at_css('turbo-frame#ticket_display_frame')).to be_present
        expect(answer.at_css('turbo-frame#ticket_display_frame [data-lane-title]').text).to include(object.title)
        expect(response.body).not_to include('<html')
      end
    end
  end

  # Probe A15 (S4a): the activity page of a project shows the object of an event in the same
  # frame, and it asks the same builder for the address. A second list of classes there would
  # drift from the one the inbox reads.
  describe 'the one builder of the frame address' do
    it 'is what the activity page of a project loads its lane from' do
      activity = project_event(organisation, project, 'note_created', actor: colleague, secondary: note,
                                                                      parameters: { 'note_title' => note.title })
      allow(Inbox::ObjectFrame).to receive(:path).and_call_original
      allow(Inbox::ObjectFrame).to receive(:path).with(note, organisation: organisation, project: project)
                                                 .and_return('/the-one-builder-answered')

      get organisation_project_activities_path(organisation, project, activity_id: activity.id)

      expect(response).to have_http_status(:ok)
      frame = Nokogiri::HTML(response.body).at_css('turbo-frame#ticket_display_frame')
      expect(frame['src']).to eq('/the-one-builder-answered')
    end
  end

  describe '"what was new"' do
    def lines(doc)
      doc.css('.inbox-new-activity__item').map { |item| item.text.squish }
    end

    it 'lists every unread event of a project row and names the object of each' do
      meeting = ActsAsTenant.with_tenant(organisation) { create(:meeting, project: project, organisation: organisation, title: 'Kickoff') }
      event_row('member_added', parameters: { 'user_name' => 'Mia Neu' }, created_at: 3.hours.ago)
      event_row('meeting_created', secondary: meeting, parameters: { 'meeting_title' => 'Kickoff' }, created_at: 2.hours.ago)
      newest = note_row(created_at: 1.hour.ago)

      found = lines(lane(newest))

      card = 'views.organisations.notifications.pane.event_card'
      expect(found.size).to eq(3)
      expect(found[0]).to include('Kai Kollege', I18n.t("#{card}.note_created.what"), 'Protokoll Kickoff')
      expect(found[1]).to include('Kai Kollege', I18n.t("#{card}.meeting_created.what"), 'Kickoff')
      expect(found[2]).to include('Kai Kollege', I18n.t("#{card}.member_added.what"), 'Mia Neu')
      # Plain lines, no links.
      expect(lane(newest).css('.inbox-new-activity a')).to be_empty
    end

    # Probe A06 (S4a): the block reads the row's own subject, not every subject of its type.
    it 'lists the events of this project only, not those of another project' do
      other_project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Lager') }
      project_event_row(organisation, other_project, 'note_created', recipient: user, actor: colleague,
                                                                     parameters: { 'note_title' => 'Inventur Lager' }, activity: false)
      mine = note_row

      found = lines(lane(mine))

      expect(found.size).to eq(1)
      expect(found.first).to include('Protokoll Kickoff')
      expect(response.body).not_to include('Inventur Lager')
    end

    it 'lists the notifications of this ticket only, not those of another ticket' do
      ticket_row = lambda do |title|
        ActsAsTenant.with_tenant(organisation) do
          ticket = create(:ticket, project: project, organisation: organisation, title: title)
          create(:notification, recipient: user, actor: colleague, organisation: organisation, project: project,
                                notifiable: ticket, event_type: 'ticket_commented', channel: 'in_app', state: :delivered)
        end
      end
      ticket_row.call('Zahlung pruefen')
      mine = ticket_row.call('Login bricht ab')

      doc = lane(mine)

      expect(doc.at_css('turbo-frame#ticket_pane').text).to include('Login bricht ab')
      expect(lines(doc).size).to eq(1)
    end

    it 'leaves out a read event' do
      event_row('member_added', parameters: { 'user_name' => 'Mia Neu' }, state: :read, read_at: 1.hour.ago)
      newest = note_row

      expect(lines(lane(newest)).size).to eq(1)
    end

    context 'for a person who may not read the tickets area' do
      let(:role) { create(:role, organisation: organisation) }

      before do
        ActsAsTenant.with_tenant(organisation) do
          create(:project_permission, user: user, project: project, notes_access: 'read_only', tickets_access: 'no_access')
        end
      end

      it 'names the note and leaves the moved ticket out, in the block and in the list' do
        moved = event_row('ticket_moved_in', parameters: { 'ticket_title' => 'GEHEIMES TICKET', 'ticket_number' => 7 },
                                             created_at: 30.minutes.ago)
        newest = note_row(created_at: 1.hour.ago)

        doc = lane(newest)

        expect(lines(doc).size).to eq(1)
        expect(lines(doc).first).to include('Protokoll Kickoff')
        expect(response.body).not_to include('GEHEIMES TICKET')

        get organisation_notifications_path(organisation, state_filters: %w[read unread])
        list = Nokogiri::HTML(response.body)
        expect(list.css('.inbox-row').map { |row| row['data-notification-id'] }).to eq([newest.id])
        expect(response.body).not_to include('GEHEIMES TICKET', moved.id)
      end
    end

    it 'lists the notifications of a ticket for a ticket row, and no event of its project' do
      ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, organisation: organisation, title: 'Login bricht ab') }
      ticket_row = ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, actor: colleague, organisation: organisation, project: project,
                              notifiable: ticket, event_type: 'ticket_commented', channel: 'in_app', state: :delivered)
      end
      note_row

      found = lines(lane(ticket_row))

      expect(found.size).to eq(1)
      expect(found.first).to include('Kai Kollege', I18n.t('views.organisations.notifications.event_short.ticket_commented'))
      expect(found.first).not_to include('Protokoll Kickoff')
    end
  end

  # An action on the open row swaps the head's buttons and nothing else of the lane: the
  # frame of a note would load again, and a draft in it would be lost.
  describe 'an action on the open row' do
    def stream_patch(path, open:)
      referer = "http://www.example.com#{organisation_notifications_path(organisation, state_filters: %w[read unread], notification: open.id)}"
      patch path, headers: { 'Accept' => 'text/vnd.turbo-stream.html', 'Referer' => referer }
      expect(response).to have_http_status(:ok)
      Nokogiri::HTML(response.body)
    end

    def pills_of(doc)
      stream = doc.at_css("turbo-stream[action='replace'][target='inbox_pane_status_pills']")
      stream && Nokogiri::HTML.fragment(stream.at_css('template').inner_html)
    end

    it 'swaps the head of an open note row to its new state and does not replace the lane' do
      row = note_row

      doc = stream_patch(mark_read_organisation_notification_path(organisation, row), open: row)

      pills = pills_of(doc)
      expect(pills.css('button').map { |button| button.text.squish }).to eq([words(:mark_unread), words(:archive)])
      expect(pills.at_css('a.inbox-lane-actions__open')['href']).to eq(note_page)
      expect(doc.css("turbo-stream[target='ticket_pane'], turbo-stream[target='ticket_display_frame']")).to be_empty
      expect(row.reload).to be_state_read
    end

    it 'swaps the head of an open card row and does not replace the lane' do
      row = event_row('member_added', parameters: { 'user_name' => 'Mia Neu' })

      doc = stream_patch(archive_organisation_notification_path(organisation, row), open: row)

      pills = pills_of(doc)
      expect(pills.css('button').map { |button| button.text.squish }).to eq([words(:unarchive)])
      expect(pills.at_css('a')).to be_nil
      expect(doc.css("turbo-stream[target='ticket_pane']")).to be_empty
    end

    it 'leaves the head alone when the acted row is not the open one' do
      open_row = note_row
      other = event_row('member_added', parameters: { 'user_name' => 'Mia Neu' })
      other.update!(notifiable: ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Lager') })

      doc = stream_patch(mark_read_organisation_notification_path(organisation, other), open: open_row)

      expect(doc.at_css("turbo-stream[target='inbox_master_list']")).to be_present
      expect(pills_of(doc)).to be_nil
    end
  end
end
