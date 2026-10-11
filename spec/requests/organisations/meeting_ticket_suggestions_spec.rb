# frozen_string_literal: true

require 'rails_helper'

# MeetingTicketSuggestionsController request specs (Gespräche Slice 8, E22). The
# security core: the run gate trio + idempotency, the CROSS-AREA accept gate
# (meetings-write is not enough — creating a ticket needs tickets-write too), the 3A
# no-double-ticket guard, dismiss, and cross-project tampering. Denial surfaces as a
# redirect (area gate) or 404 (record scoped out) — the cross-area accept denial is
# a deliberate 403. The async job is stubbed; ai_available? is stubbed true.
RSpec.describe 'Organisations::MeetingTicketSuggestions', type: :request do
  let(:organisation) { create(:organisation, ai_enabled: true, assistant_enabled: true) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  def user_with_access(meetings, tickets: nil, assistant: false, on: project)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true) if assistant
      perms = {}
      perms[:meetings_access] = meetings unless meetings == :none
      perms[:tickets_access] = tickets if tickets
      create(:project_permission, user: user, project: on, **perms) if perms.any?
    end
    user
  end

  let(:writer)  { user_with_access('read_write', assistant: true) }         # meetings write + assistant
  let(:editor)  { user_with_access('read_write', tickets: 'read_write') }   # can accept (creates ticket)
  let(:reader)  { user_with_access('read_only') }

  let(:meeting) do
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting, project: project, organisation: organisation, creator: writer, transcript: 'Gesprächstext.')
    end
  end

  def in_org(&) = ActsAsTenant.with_tenant(organisation, &)

  def suggestion_for(**attrs)
    in_org { create(:meeting_ticket_suggestion, meeting: meeting, **attrs) }
  end

  # R2: the controller and the section partial ask
  # ai_available_for?(:meeting_ticket_suggestions). Stubbed at the ANSWER — a real
  # Availability, built through the registry's own struct — so the stub has the shape
  # the call sites read (.available?), not a boolean they would have to be rewritten for.
  #
  # SCOPED TO THE KEY, and that is the whole point. A stub without `with` answers for
  # every key, so a call site keyed to any other feature keeps passing — which makes
  # this file blind to the one defect R2 can introduce (measured: with a blanket stub,
  # retyping the controller's key to :chat left 86 examples green). Foreign keys fall
  # through to the real registry, and the test org has no usable credential, so a
  # mis-keyed gate resolves to "unavailable" and the positive examples below go red.
  def stub_ai_availability(available, reason: nil, feature: :meeting_ticket_suggestions)
    stub_ai_availabilities(reason: reason, feature => available)
  end

  # Several keys in ONE call, each with its own answer. The section asks two keys since
  # the run starts from the assistant composer (:meeting_ticket_suggestions AND :chat).
  # Two separate calls would not do: each re-installs the call_original catch-all, and
  # RSpec matches the newest stub first, so the second call shadows the first one's key.
  def stub_ai_availabilities(reason: nil, **answers)
    allow_any_instance_of(Organisation).to receive(:ai_available_for?).and_call_original
    answers.each do |feature, available|
      allow_any_instance_of(Organisation).to receive(:ai_available_for?).with(feature).and_return(
        Lalabase::Llm::FeatureRegistry::Availability.new(available: available, reason: reason)
      )
    end
  end

  before do
    stub_ai_availability(true)
    allow(Meetings::TicketSuggestionRunJob).to receive(:enqueue_run)
    allow(Meetings::TicketSuggestionRunJob).to receive(:perform_later)
  end

  let(:run_path) { run_organisation_project_meeting_ticket_suggestions_path(organisation, project, meeting) }
  def accept_path(suggestion) = accept_organisation_project_meeting_ticket_suggestion_path(organisation, project, meeting, suggestion)
  def dismiss_path(suggestion) = dismiss_organisation_project_meeting_ticket_suggestion_path(organisation, project, meeting, suggestion)

  describe 'POST run' do
    it 'does not run an old meeting endpoint without assistant permission' do
      sign_in editor

      expect do
        post run_path, as: :turbo_stream
      end.not_to(change { in_org { MeetingTicketSuggestionRun.count } })

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include(I18n.t('flash.meeting_ticket_suggestions.assistant_unavailable'))
      expect(Meetings::TicketSuggestionRunJob).not_to have_received(:enqueue_run)
    end

    it 'immediately shows an enqueue failure instead of a started message or spinner' do
      allow(Meetings::TicketSuggestionRunJob).to receive(:enqueue_run).and_call_original
      allow_any_instance_of(Meetings::TicketSuggestionRunJob).to receive(:enqueue).and_return(false)
      sign_in writer

      post run_path, as: :turbo_stream

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('assistant_suggestions.interrupted'))
      expect(response.body).not_to include(I18n.t('flash.meeting_ticket_suggestions.started'))
      expect(response.body).not_to include(I18n.t('views.organisations.meetings.ticket_suggestions.in_progress'))
      expect(in_org { meeting.reload.suggestions_creation_flag }).to be(false)
      expect(meeting.suggestions_creation_error).to eq(I18n.t('assistant_suggestions.interrupted'))
    end

    it 'sets the pending flag and enqueues the job for a meetings writer' do
      sign_in writer
      post run_path, as: :turbo_stream
      expect(Meetings::TicketSuggestionRunJob).to have_received(:enqueue_run).with(run: have_attributes(meeting_id: meeting.id))
      expect(in_org { meeting.reload.suggestions_creation_flag }).to be(true)
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(meeting, :ticket_suggestions))
    end

    it 'is idempotent: no second job while a run is already in progress' do
      in_org { meeting.update!(suggestions_creation_flag: true) }
      sign_in writer
      post run_path, as: :turbo_stream
      expect(Meetings::TicketSuggestionRunJob).not_to have_received(:enqueue_run)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'does not enqueue when the meeting has no source (blank transcript + notes)' do
      blank = in_org { create(:meeting, project: project, organisation: organisation, creator: writer) }
      sign_in writer
      post run_organisation_project_meeting_ticket_suggestions_path(organisation, project, blank), as: :turbo_stream
      expect(Meetings::TicketSuggestionRunJob).not_to have_received(:enqueue_run)
    end

    it 'does not enqueue when AI is unavailable' do
      stub_ai_availability(false, reason: :no_credential)
      sign_in writer
      post run_path, as: :turbo_stream
      expect(Meetings::TicketSuggestionRunJob).not_to have_received(:enqueue_run)
    end

    it 'rejects a meetings reader with a redirect and enqueues nothing' do
      sign_in reader
      post run_path
      expect(Meetings::TicketSuggestionRunJob).not_to have_received(:enqueue_run)
      expect(response).to have_http_status(:redirect)
    end

    it 'is 404 when the meeting belongs to a different project (set_meeting scoping)' do
      other_project = in_org { create(:project, organisation: organisation) }
      foreign_meeting = in_org { create(:meeting, project: other_project, organisation: organisation, creator: writer) }
      sign_in writer
      post run_organisation_project_meeting_ticket_suggestions_path(organisation, project, foreign_meeting)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST accept (cross-area write)' do
    it 'creates ONE ticket + a meeting link and marks the suggestion accepted (editor)' do
      suggestion = suggestion_for(title: 'Rechnung senden', description: 'An Kunde X.')
      sign_in editor

      expect { post accept_path(suggestion), as: :turbo_stream }.to change { in_org { Ticket.count } }.by(1)

      in_org do
        suggestion.reload
        expect(suggestion).to be_accepted
        ticket = Ticket.find(suggestion.created_ticket_id)
        expect(ticket.title).to eq('Rechnung senden')
        expect(meeting.outgoing_references.where(target_type: Ticket.polymorphic_name).first.target_id).to eq(ticket.id)
      end
      expect(response.body).to include('data-meeting-section-sync-announce-links-value="true"')
    end

    it 'rejects a meetings writer WITHOUT tickets-write with 403 and creates no ticket' do
      suggestion = suggestion_for
      sign_in writer # meetings write, NO tickets write

      expect { post accept_path(suggestion), as: :turbo_stream }.not_to(change { in_org { Ticket.count } })
      expect(response).to have_http_status(:forbidden)
      expect(in_org { suggestion.reload }).to be_open
    end

    it '3A: a second accept creates no second ticket (already processed)' do
      suggestion = suggestion_for
      sign_in editor

      expect { post accept_path(suggestion), as: :turbo_stream }.to change { in_org { Ticket.count } }.by(1)
      expect { post accept_path(suggestion), as: :turbo_stream }.not_to(change { in_org { Ticket.count } })
      expect(in_org { suggestion.reload }).to be_accepted
    end

    it 'is 404 for a suggestion id from a different meeting (tampering)' do
      other_meeting = in_org { create(:meeting, project: project, organisation: organisation, creator: writer) }
      foreign = in_org { create(:meeting_ticket_suggestion, meeting: other_meeting) }
      sign_in editor
      post accept_organisation_project_meeting_ticket_suggestion_path(organisation, project, meeting, foreign)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST dismiss' do
    it 'dismisses an open suggestion for a meetings writer (no tickets access needed)' do
      suggestion = suggestion_for
      sign_in writer
      post dismiss_path(suggestion), as: :turbo_stream
      expect(in_org { suggestion.reload }).to be_dismissed
      expect(response.body).to include('data-meeting-section-sync-announce-links-value="false"')
    end

    it 'rejects a meetings reader with a redirect and keeps the suggestion open' do
      suggestion = suggestion_for
      sign_in reader
      post dismiss_path(suggestion)
      expect(response).to have_http_status(:redirect)
      expect(in_org { suggestion.reload }).to be_open
    end

    it 'redirects an unauthenticated user to login' do
      suggestion = suggestion_for
      post dismiss_path(suggestion)
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  # The meeting show route renders the full master-detail (incl. _meeting_show and
  # the ticket-suggestions section) server-side when a meeting is selected.
  describe 'meeting detail rendering (Ticket-Vorschläge section)' do
    let(:similar_ticket) do
      in_org { create(:ticket, project: project, organisation: organisation, creator: writer, title: 'BESTEHENDES-TICKET-XYZ') }
    end
    let(:hint_key) { I18n.t('views.organisations.meetings.ticket_suggestions.similar_ticket') }

    def show_body
      get organisation_project_meeting_path(organisation, project, meeting)
      response.body
    end

    it 'renders the section frame with the generate button for a meetings writer + AI' do
      sign_in writer
      body = show_body
      expect(body).to include(ActionView::RecordIdentifier.dom_id(meeting, :ticket_suggestions))
      expect(body).to include(I18n.t('views.organisations.meetings.ticket_suggestions.generate'))
    end

    it 'lists an open suggestion with accept + dismiss for an editor (tickets write)' do
      suggestion = suggestion_for(title: 'VORSCHLAG-ABC')
      sign_in editor
      body = show_body
      expect(body).to include('VORSCHLAG-ABC')
      # Assert on the form action paths (the button label also appears in the intro).
      expect(body).to include(accept_path(suggestion))
      expect(body).to include(dismiss_path(suggestion))
    end

    it 'hides the accept button (only dismiss) for a meetings writer WITHOUT tickets-write' do
      suggestion = suggestion_for
      sign_in writer
      body = show_body
      expect(body).not_to include(accept_path(suggestion))
      expect(body).to include(dismiss_path(suggestion))
    end

    # 7A: the WHOLE similar-ticket hint (label + linked title) is tickets-read-gated.
    it 'shows the similar-ticket hint to a user WITH tickets-read' do
      suggestion_for(similar_ticket: similar_ticket)
      sign_in(user_with_access('read_only', tickets: 'read_only'))
      body = show_body
      expect(body).to include('BESTEHENDES-TICKET-XYZ')
      expect(body).to include(hint_key)
    end

    it 'does NOT leak the similar-ticket title to a meetings-only user (7A negative)' do
      suggestion_for(similar_ticket: similar_ticket)
      sign_in reader # meetings read, NO tickets read
      body = show_body
      expect(body).not_to include('BESTEHENDES-TICKET-XYZ')
      expect(body).not_to include(hint_key)
    end

    it 'keeps the empty result area readable but disables creation when AI is unavailable' do
      allow_any_instance_of(Organisation).to receive(:ai_enabled?).and_return(false)
      stub_ai_availability(false, reason: :ai_disabled)
      sign_in writer
      body = show_body
      html = Nokogiri::HTML(body)
      expect(body).to include(I18n.t('views.organisations.meetings.ticket_suggestions.heading'))
      expect(body).to include(I18n.t('views.organisations.meetings.ticket_suggestions.assistant_unavailable'))
      frame_id = ActionView::RecordIdentifier.dom_id(meeting, :ticket_suggestions)
      expect(html.at_css("##{frame_id} button[disabled]")).to be_present
    end

    def frame_node
      Nokogiri::HTML(response.body).at_css("##{ActionView::RecordIdentifier.dom_id(meeting, :ticket_suggestions)}")
    end

    def entry_button(label_key)
      frame_node&.css('button')&.find { |button| button.text.squish == I18n.t("views.organisations.meetings.ticket_suggestions.#{label_key}") }
    end

    # The legacy POST remains deployment-compatible, but the current surface must enter
    # the assistant and gate availability on the ticket-suggestion feature AND :chat.
    it 'offers the assistant entry when both its feature key and the chat rung say yes' do
      stub_ai_availabilities(meeting_ticket_suggestions: true, chat: true)
      sign_in writer
      body = show_body
      expect(body).to include('data-assistant-trigger-intent-value="ticket-suggestions"')
      expect(body).not_to include("action=\"#{run_path}\"")
      expect(entry_button(:generate).key?('disabled')).to be(false)
    end

    # The run starts from the assistant composer, a :chat surface: the feature key alone
    # would open a composer that cannot send.
    it 'disables the entry when the chat rung is unavailable, even though the feature key says yes' do
      stub_ai_availabilities(meeting_ticket_suggestions: true, chat: false)
      sign_in writer
      show_body

      button = entry_button(:generate)
      expect(button.key?('disabled')).to be(true)
      expect(button['data-assistant-trigger-intent-value']).to be_nil
      expect(frame_node.text).to include(I18n.t('views.organisations.meetings.ticket_suggestions.assistant_unavailable'))
    end

    it 'disables the entry when the feature key is unavailable, even though the chat rung says yes' do
      stub_ai_availabilities(meeting_ticket_suggestions: false, chat: true)
      sign_in writer
      show_body

      expect(entry_button(:generate).key?('disabled')).to be(true)
      expect(response.body).not_to include('data-assistant-trigger-intent-value="ticket-suggestions"')
    end

    # A disabled "Neu ableiten" needs its reason in sight next to existing suggestions
    # too, and its title must not advertise the action it cannot perform.
    it 'names the reason next to existing suggestions when regenerating is disabled' do
      suggestion_for(title: 'VORSCHLAG-OFFLINE')
      stub_ai_availabilities(meeting_ticket_suggestions: true, chat: false)
      sign_in writer
      show_body

      button = entry_button(:regenerate)
      hint = frame_node.at_css("##{button['aria-describedby']}")
      expect(button.key?('disabled')).to be(true)
      expect(button['title']).to be_nil
      expect(hint.text.squish).to eq(I18n.t('views.organisations.meetings.ticket_suggestions.assistant_unavailable'))
      expect(frame_node.text).to include('VORSCHLAG-OFFLINE')
    end

    # Rollout decision A: creation is assistant-only, but a writer in an AI org whose
    # assistant gate is closed keeps the section and learns where creation went.
    it 'tells a writer without the assistant where creation went, without an entry button' do
      sign_in editor # meetings + tickets write, NO use_assistant
      show_body

      expect(frame_node.text).to include(I18n.t('views.organisations.meetings.ticket_suggestions.assistant_not_enabled'))
      expect(frame_node.text).not_to include(I18n.t('views.organisations.meetings.ticket_suggestions.empty'))
      expect(entry_button(:generate)).to be_nil
      expect(response.body).not_to include('data-assistant-trigger-intent-value="ticket-suggestions"')
    end

    it 'keeps existing suggestions actionable next to that hint' do
      suggestion = suggestion_for(title: 'VORSCHLAG-OHNE-ASSISTENT')
      sign_in editor
      body = show_body

      expect(frame_node.text).to include('VORSCHLAG-OHNE-ASSISTENT', I18n.t('views.organisations.meetings.ticket_suggestions.assistant_not_enabled'))
      expect(body).to include(accept_path(suggestion))
      expect(entry_button(:regenerate)).to be_nil
    end
  end
end
