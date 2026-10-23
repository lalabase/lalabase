# frozen_string_literal: true

require 'rails_helper'

# The meeting beside the ticket (doc/ticket_meeting_panel_plan.md, S1). The panel reads a
# meeting of the ticket into turbo-frame#ticket_meeting_panel. Who may see which meeting is
# Tickets::LinkedMeetings (each meeting against its OWN project, S0); everything the reader
# may not see, and everything that does not exist, is one 404 with one body.
RSpec.describe 'Ticket meeting panel', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:creator) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: creator, title: 'Ticket-With-Meetings')
    end
  end

  def meeting_in(target_project, title:, occurred_at: 1.day.ago, **attributes)
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting, project: target_project, organisation: organisation, creator: creator,
                       title: title, occurred_at: occurred_at, **attributes)
    end
  end

  def link(meeting, to: ticket)
    ActsAsTenant.with_tenant(organisation) do
      meeting.outgoing_references.create!(organisation: organisation, target: to, target_title_snapshot: to.display_title)
    end
  end

  def member(**access)
    create(:user).tap do |user|
      ActsAsTenant.with_tenant(organisation) do
        role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
        create(:membership, user: user, organisation: organisation, role: role, active: true)
        create(:project_permission, { user: user, project: project }.merge(access)) if access.any?
      end
    end
  end

  def grant(user, target_project, **access)
    ActsAsTenant.with_tenant(organisation) { create(:project_permission, user: user, project: target_project, **access) }
  end

  let(:reader) { member(tickets_access: 'read_only', meetings_access: 'read_only') }
  let(:frame) { { 'Turbo-Frame' => 'ticket_meeting_panel' } }

  def panel(meeting_id: nil, ticket_id: ticket.id, project_id: project.id, org: organisation, headers: frame)
    params = meeting_id ? { meeting_id: meeting_id } : {}
    get organisation_project_ticket_meeting_panel_path(org, project_id, ticket_id), params: params, headers: headers
  end

  def unavailable_text = I18n.t('views.organisations.tickets.meeting_panel.unavailable')

  describe 'a frame request' do
    let!(:meeting) do
      meeting_in(project, title: 'Kickoff-Panel-QX', notes: 'Notes-Body-QX', transcript: 'Transcript-Body-QX',
                          generated_summary: 'Summary-Body-QX').tap { |m| link(m) }
    end

    before do
      ActsAsTenant.with_tenant(organisation) { create(:meeting_participant, meeting: meeting, display_name: 'Participant-QX') }
    end

    it 'renders the meeting into the panel frame' do
      sign_in reader
      panel

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)
      frame_element = document.at_css('turbo-frame#ticket_meeting_panel')
      expect(frame_element).not_to be_nil
      expect(frame_element.text).to include('Kickoff-Panel-QX', 'Participant-QX', 'Summary-Body-QX', 'Notes-Body-QX',
                                            'Transcript-Body-QX')
      expect(frame_element.at_css('[data-controller~="ticket-meeting-panel"]')['data-ticket-meeting-panel-ticket-id-value'])
        .to eq(ticket.id)
      # A fragment for the frame, not a page around it.
      expect(response.body).not_to match(/<html/i)
    end

    it 'is read only: no form, no edit, delete, analyses, suggestions or assistant entry point' do
      sign_in member(tickets_access: 'read_write', meetings_access: 'read_write')
      panel

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).not_to include('<form')
      expect(body).not_to include(edit_organisation_project_meeting_path(organisation, project, meeting))
      expect(body).not_to include('data-turbo-method')
      expect(body).not_to include('assistant-trigger')
      expect(body).not_to include(ActionView::RecordIdentifier.dom_id(meeting, :ticket_links))
      expect(body).not_to include('analyses')
      expect(body).not_to include('ticket_suggestions')
    end

    it 'collapses the transcript' do
      sign_in reader
      panel

      transcript = Nokogiri::HTML(response.body).css('[data-controller="clamp-toggle"]')
                           .find { |node| node.text.include?('Transcript-Body-QX') }
      expect(transcript).not_to be_nil
    end

    it 'collapses the transcript also when it is the only text of the meeting' do
      only_transcript = meeting_in(project, title: 'Only-Transcript-QX', transcript: 'Lonely-Transcript-QX').tap { |m| link(m) }
      sign_in reader
      panel(meeting_id: only_transcript.id)

      transcript = Nokogiri::HTML(response.body).css('[data-controller="clamp-toggle"]')
                           .find { |node| node.text.include?('Lonely-Transcript-QX') }
      expect(transcript).not_to be_nil
    end

    it 'accepts the meeting id in capitals, as the database does' do
      sign_in reader
      panel(meeting_id: meeting.id.upcase)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Kickoff-Panel-QX')
    end

    { 'first summary' => '', 'regenerated summary' => 'Summary-Body-QX' }.each do |state, existing_summary|
      it "refreshes a pending #{state} into the read-only panel" do
        ActsAsTenant.with_tenant(organisation) do
          meeting.update!(generated_summary: existing_summary, summary_creation_flag: true)
        end
        sign_in reader
        panel

        expect(response).to have_http_status(:ok)
        document = Nokogiri::HTML(response.body)
        status = document.at_css('[role="status"]')
        expect(status).not_to be_nil
        expect(status.text).to include(I18n.t('views.organisations.meetings.show.summary_in_progress'))
        refresh = status.at_css('a')
        expect(refresh['href']).to eq(organisation_project_ticket_meeting_panel_path(organisation, project, ticket, meeting_id: meeting.id))
        expect(refresh.text).to include(I18n.t('views.organisations.meetings.show.summary_refresh'))
        expect(refresh['data-turbo-frame']).to eq('ticket_meeting_panel')
        expect(document.css('form')).to be_empty
        expect(response.body).not_to include('meeting_display_frame')

        ActsAsTenant.with_tenant(organisation) do
          meeting.update!(generated_summary: 'Finished-Summary-QX', summary_creation_flag: false)
        end
        get refresh['href'], headers: frame

        expect(response).to have_http_status(:ok)
        refreshed_panel = Nokogiri::HTML(response.body).at_css('turbo-frame#ticket_meeting_panel')
        expect(refreshed_panel.text).to include('Finished-Summary-QX')
        expect(refreshed_panel.css('[role="status"], form')).to be_empty
      end
    end

    it 'offers the meeting page and leaves the frame for it' do
      sign_in reader
      panel

      anchor = Nokogiri::HTML(response.body)
                       .at_css(%(a[href="#{organisation_project_meetings_path(organisation, project, meeting_id: meeting.id)}"]))
      expect(anchor).not_to be_nil
      expect(anchor['data-turbo-frame']).to eq('_top')
    end
  end

  # S3: with the assistant available the panel NAMES its meeting, so the assistant can
  # offer it after the ticket. A name, not a button: still no trigger.
  describe 'with the assistant available' do
    let(:organisation) do
      create(:organisation, assistant_enabled: true, ai_enabled: true,
                            ai_provider: 'openai', ai_access_token: 'sk-org-own-1234567890abcdef')
    end
    let!(:meeting) { meeting_in(project, title: 'Named-Meeting-QX').tap { |m| link(m) } }

    it 'names the meeting to the assistant and offers no trigger' do
      user = reader
      ActsAsTenant.with_tenant(organisation) do
        role = user.memberships.find_by(organisation: organisation).role
        create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
      end
      sign_in user
      panel

      root = Nokogiri::HTML(response.body).at_css('[data-controller~="ticket-meeting-panel"]')
      expect(root['data-assistant-context']).to eq(meeting.id)
      expect(root['data-assistant-context-type']).to eq('Meeting')
      expect(root['data-assistant-context-label']).to include('Named-Meeting-QX')
      expect(response.body).not_to include('assistant-trigger')
    end
  end

  describe 'several meetings' do
    let!(:older) { meeting_in(project, title: 'Older-QX', occurred_at: 3.days.ago).tap { |m| link(m) } }
    let!(:newest) { meeting_in(project, title: 'Newest-QX', occurred_at: 1.day.ago).tap { |m| link(m) } }

    it 'opens the newest and offers every meeting as a tab' do
      sign_in reader
      panel

      document = Nokogiri::HTML(response.body)
      expect(document.at_css('h2').text).to include('Newest-QX')
      tabs = document.css('nav.ticket-meeting-panel__tabs a')
      expect(tabs.map { |tab| tab['href'] }).to eq([
                                                     organisation_project_ticket_meeting_panel_path(organisation, project, ticket, meeting_id: newest.id),
                                                     organisation_project_ticket_meeting_panel_path(organisation, project, ticket, meeting_id: older.id)
                                                   ])
      expect(tabs.first['aria-current']).to eq('true')
      expect(tabs.last['aria-current']).to be_nil
    end

    it 'opens the meeting a tab names' do
      sign_in reader
      panel(meeting_id: older.id)

      expect(Nokogiri::HTML(response.body).at_css('h2').text).to include('Older-QX')
    end

    it 'shows no tabs for a single meeting' do
      single = ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: creator)
      end
      link(older, to: single)
      sign_in reader
      panel(ticket_id: single.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('ticket-meeting-panel__tabs')
    end
  end

  describe 'the linked tickets of the open meeting' do
    let(:meeting) { meeting_in(project, title: 'Linked-Tickets-QX').tap { |m| link(m) } }
    let(:sibling) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: creator, title: 'Sibling-QX')
      end
    end
    let(:elsewhere_project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
    let(:elsewhere) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: elsewhere_project, organisation: organisation, creator: creator, title: 'Elsewhere-QX')
      end
    end

    before do
      link(meeting, to: sibling)
      link(meeting, to: elsewhere)
    end

    it 'opens a ticket of this project in the lane, names this ticket without a link' do
      sign_in reader
      panel

      document = Nokogiri::HTML(response.body)
      sibling_link = document.at_css(%(a[data-ticket-id="#{sibling.id}"]))
      expect(sibling_link['data-action']).to eq('ticket-meeting-panel#openTicket')
      expect(sibling_link['data-turbo-frame']).to be_nil
      expect(sibling_link['href']).to eq(organisation_project_tickets_path(organisation, project, ticket_id: sibling.id))
      expect(document.css('a').map(&:text)).not_to include('Ticket-With-Meetings')
      expect(document.text).to include('Ticket-With-Meetings')
    end

    it 'lists the linked tickets oldest link first' do
      ActsAsTenant.with_tenant(organisation) do
        Reference.where(source: meeting, target: sibling).update_all(created_at: 2.hours.ago)
      end
      sign_in reader
      panel

      titles = Nokogiri::HTML(response.body).css('section li').map { |item| item.text.squish }
      expect(titles.index { |text| text.include?('Sibling-QX') })
        .to be < titles.index { |text| text.include?('Ticket-With-Meetings') }
    end

    it 'hides a linked ticket the reader may not read' do
      sign_in reader
      panel

      expect(response.body).not_to include('Elsewhere-QX')
    end

    it 'leaves the page for a readable ticket of another project' do
      user = reader
      grant(user, elsewhere_project, tickets_access: 'read_only')
      sign_in user
      panel

      anchor = Nokogiri::HTML(response.body)
                       .at_css(%(a[href="#{organisation_project_tickets_path(organisation, elsewhere_project, ticket_id: elsewhere.id)}"]))
      expect(anchor['data-turbo-frame']).to eq('_top')
    end
  end

  describe 'what is not there, or not for this reader' do
    let(:meeting) { meeting_in(project, title: 'Hidden-QX').tap { |m| link(m) } }

    def expect_unavailable
      expect(response).to have_http_status(:not_found)
      expect(response.body).to include('turbo-frame id="ticket_meeting_panel"', unavailable_text)
      expect(response.body).not_to include('Hidden-QX')
      expect(response.body).not_to match(/<html/i)
    end

    # The ticket comes from the project of the address, not from anywhere the reader may look.
    it 'is a 404 for the ticket under the address of another project' do
      meeting
      other_project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      user = reader
      grant(user, other_project, tickets_access: 'read_only', meetings_access: 'read_only')
      sign_in user
      panel(project_id: other_project.id)

      expect_unavailable
    end

    # Two locks: the scope finds the meeting, and MeetingPolicy#show? is asked as well.
    # They answer alike today; this keeps the second one from going as redundant.
    it 'shows nothing when MeetingPolicy#show? refuses a meeting the scope found' do
      meeting
      allow(MeetingPolicy).to receive(:new).and_wrap_original do |original, *args|
        original.call(*args).tap { |policy| allow(policy).to receive(:show?).and_return(false) }
      end
      sign_in reader
      panel

      expect(response).not_to have_http_status(:ok)
      expect(response.body).not_to include('Hidden-QX')
    end

    it 'is a 404 for a meeting that does not link to the ticket' do
      unlinked = meeting_in(project, title: 'Unlinked-QX')
      meeting
      sign_in reader
      panel(meeting_id: unlinked.id)

      expect_unavailable
      expect(response.body).not_to include('Unlinked-QX')
    end

    it 'is a 404 for a meeting id that does not exist' do
      meeting
      sign_in reader
      panel(meeting_id: SecureRandom.uuid)

      expect_unavailable
    end

    it 'is a 404 for a ticket that does not exist' do
      sign_in reader
      panel(ticket_id: SecureRandom.uuid)

      expect_unavailable
    end

    it 'is a 404 without meetings read' do
      meeting
      sign_in member(tickets_access: 'read_only')
      panel(meeting_id: meeting.id)

      expect_unavailable
    end

    it 'is a 404 without tickets read' do
      meeting
      sign_in member(meetings_access: 'read_only')
      panel(meeting_id: meeting.id)

      expect_unavailable
    end

    it 'answers every one of these with the same body' do
      meeting
      bodies = []
      sign_in reader
      panel(meeting_id: SecureRandom.uuid)
      bodies << response.body
      panel(meeting_id: meeting_in(project, title: 'Other-QX').id)
      bodies << response.body
      sign_in member(tickets_access: 'read_only')
      panel(meeting_id: meeting.id)
      bodies << response.body
      sign_in member(meetings_access: 'read_only')
      panel(meeting_id: meeting.id)
      bodies << response.body

      expect(bodies.uniq.size).to eq(1)
    end

    it 'shows nothing of another organisation' do
      meeting
      foreign_org = create(:organisation)
      foreign_project = ActsAsTenant.with_tenant(foreign_org) { create(:project, organisation: foreign_org) }
      sign_in reader
      panel(org: foreign_org, project_id: foreign_project.id)

      # Not a member there: the organisation filter answers before this controller does.
      expect(response).not_to have_http_status(:ok)
      expect(response.body).not_to include('Hidden-QX')
    end

    it 'shows nothing of another organisation through this organisation' do
      foreign_org = create(:organisation)
      foreign_project = ActsAsTenant.with_tenant(foreign_org) { create(:project, organisation: foreign_org) }
      foreign_ticket = ActsAsTenant.with_tenant(foreign_org) do
        create(:ticket, project: foreign_project, organisation: foreign_org, creator: creator)
      end
      sign_in reader
      panel(project_id: foreign_project.id, ticket_id: foreign_ticket.id)

      expect_unavailable
    end
  end

  # S0: a ticket moved out of its meeting's project keeps the link. The panel judges the
  # meeting against the MEETING's project.
  describe 'a ticket moved to another project' do
    let(:project_b) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
    let(:meeting) { meeting_in(project, title: 'Before-Move-QX').tap { |m| link(m) } }

    before do
      meeting
      ActsAsTenant.with_tenant(organisation) do
        grant(creator, project, tickets_access: 'read_write', meetings_access: 'read_write')
        grant(creator, project_b, tickets_access: 'read_write', meetings_access: 'read_write')
        Tickets::Mover.call(ticket: ticket, target_project: project_b, current_user: creator)
      end
    end

    it 'is a 404 for a reader of meetings in the new project only' do
      user = member
      grant(user, project_b, tickets_access: 'read_only', meetings_access: 'read_only')
      sign_in user
      panel(project_id: project_b.id)

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include('Before-Move-QX')
    end

    it "shows the meeting to a reader of meetings in the meeting's project" do
      user = member(meetings_access: 'read_only')
      grant(user, project_b, tickets_access: 'read_only')
      sign_in user
      panel(project_id: project_b.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Before-Move-QX')
      expect(response.body).to include(organisation_project_meetings_path(organisation, project, meeting_id: meeting.id))
    end

    it "sends a request outside the frame to the meeting's page in the meeting's project" do
      user = member(meetings_access: 'read_only')
      grant(user, project_b, tickets_access: 'read_only')
      sign_in user
      panel(project_id: project_b.id, headers: {})

      expect(response).to redirect_to(organisation_project_meetings_path(organisation, project, meeting_id: meeting.id))
    end
  end

  describe 'a request that is not for the panel frame' do
    let(:meeting) { meeting_in(project, title: 'Redirect-QX').tap { |m| link(m) } }

    it "goes to the meeting's own page" do
      meeting
      sign_in reader
      panel(meeting_id: meeting.id, headers: {})

      expect(response).to redirect_to(organisation_project_meetings_path(organisation, project, meeting_id: meeting.id))
    end

    it 'goes to the newest meeting without a meeting id' do
      meeting
      sign_in reader
      panel(headers: {})

      expect(response).to redirect_to(organisation_project_meetings_path(organisation, project, meeting_id: meeting.id))
    end

    it 'goes to the meeting page also for a request of another frame' do
      meeting
      sign_in reader
      panel(meeting_id: meeting.id, headers: { 'Turbo-Frame' => 'ticket_display_frame' })

      expect(response).to have_http_status(:redirect)
    end

    it 'is a plain 404 for what is not there' do
      sign_in reader
      panel(meeting_id: SecureRandom.uuid, headers: {})

      # The test environment's 404 page prints the spec source, as text: an element is
      # what tells the frame's answer from the application's.
      expect(response).to have_http_status(:not_found)
      expect(Nokogiri::HTML(response.body).at_css('turbo-frame#ticket_meeting_panel')).to be_nil
    end
  end

  # How an entry of the ticket's meetings section opens is named by the owner of
  # turbo-frame#ticket_display_frame (components/ticket_meeting_panel.css shows that form).
  describe "the ticket's meetings section" do
    let(:meeting) { meeting_in(project, title: 'Section-QX').tap { |m| link(m) } }

    it 'carries the panel, text and page forms of every entry' do
      meeting
      sign_in reader
      get organisation_project_ticket_path(organisation, project, ticket)

      entry = Nokogiri::HTML(response.body).at_css("#meeting-references-#{ticket.id} li")
      panel_link = entry.at_css('a.meeting-reference--panel')
      expect(panel_link['href']).to eq(organisation_project_ticket_meeting_panel_path(organisation, project, ticket, meeting_id: meeting.id))
      expect(panel_link['data-turbo-frame']).to eq('ticket_meeting_panel')
      expect(entry.at_css('span.meeting-reference--text').text).to eq('Section-QX')
      expect(entry.at_css('a.meeting-reference--page')['data-turbo-frame']).to eq('_top')
    end

    it 'names the panel form on the lane of the ticket page and offers the empty panel frame' do
      meeting
      sign_in reader
      get organisation_project_tickets_path(organisation, project, ticket_id: ticket.id)

      document = Nokogiri::HTML(response.body)
      expect(document.at_css('turbo-frame#ticket_display_frame')['data-meeting-links']).to eq('panel')
      panel_frame = document.at_css('.layout aside.column.panel turbo-frame#ticket_meeting_panel')
      expect(panel_frame).not_to be_nil
      expect(panel_frame.children.reject(&:text?)).to be_empty
      expect(document.at_css('.layout')['class']).to include('hide-panel')
    end

    it 'names the page form on the phone' do
      meeting
      sign_in reader
      get organisation_project_tickets_path(organisation, project, ticket_id: ticket.id, viewport: 'mobile')

      expect(Nokogiri::HTML(response.body).at_css('turbo-frame#ticket_display_frame')['data-meeting-links']).to eq('page')
    end

    it 'names the text form in the inbox pane' do
      meeting
      user = reader
      notification = ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation, project: project,
                              notifiable: ticket, channel: 'in_app', state: :delivered)
      end
      sign_in user
      Prosopite.pause
      get organisation_notifications_path(organisation), params: { notification: notification.id }
      Prosopite.resume

      document = Nokogiri::HTML(response.body)
      expect(document.at_css('turbo-frame#ticket_display_frame')['data-meeting-links']).to eq('text')
      expect(document.at_css("#meeting-references-#{ticket.id} span.meeting-reference--text").text).to eq('Section-QX')
    end
  end
end
