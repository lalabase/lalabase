# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Assistant ticket suggestions', type: :request do
  include_context 'assistant ticket suggestions'

  before { sign_in user }

  def run_path(run, action: nil, **params)
    prefix = action ? "#{action}_" : ''
    public_send("#{prefix}organisation_assistant_chat_ticket_suggestion_run_path", organisation, run.chatpost.chat, run, **params)
  end

  it 'creates a first conversation with a structured task, without a chat job or tickets' do
    expect do
      post organisation_assistant_chats_path(organisation), params: {
        chat: { reference_keys: ["Meeting:#{meeting.id}"], chatposts_attributes: { '0' => { content: 'Leite Aufgaben ab.', ticket_suggestion_meeting_id: meeting.id } } }
      }, as: :turbo_stream
    end.not_to(change { in_org { Ticket.count } })
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Aufgaben aus Planungsrunde', 'Zielprojekt', project.name)
    expect(Meetings::TicketSuggestionRunJob).to have_been_enqueued.exactly(:once)
    expect(ChatResponseJob).not_to have_received(:perform_later)
    expect(in_org { MeetingTicketSuggestionRun.count }).to eq(1)
  end

  it 'rejects a forged target without creating a message, run or normal chat job' do
    foreign = create(:meeting, project: project, organisation: organisation, creator: user, notes: 'Other')
    thread = chat
    expect do
      post organisation_assistant_chat_chatposts_path(organisation, thread), params: { chatpost: { content: 'do it', ticket_suggestion_meeting_id: foreign.id } }, as: :turbo_stream
    end.not_to(change { in_org { Chatpost.count } })
    expect(response.body).to include('keine Berechtigung')
    expect(ChatResponseJob).not_to have_received(:perform_later)
    expect(Meetings::TicketSuggestionRunJob).not_to have_been_enqueued
  end

  it 'keeps normal natural language task questions on the ordinary chat path' do
    post organisation_assistant_chat_chatposts_path(organisation, chat), params: { chatpost: { content: 'Welche Aufgaben haben wir?' } }, as: :turbo_stream
    expect(ChatResponseJob).to have_received(:perform_later).once
    expect(Meetings::TicketSuggestionRunJob).not_to have_been_enqueued
  end

  it 'renders the fixed meeting after references change and accepts only stored text exactly once' do
    run = finish_run(start_run)
    chat.update!(scope_references: [])
    get run_path(run)
    expect(response.body).to include(meeting.title, project.name, 'Rechnung senden')
    suggestion = in_org { run.meeting_ticket_suggestions.first }
    expect do
      post run_path(run, action: :accept, suggestion_id: suggestion.id), params: { title: 'INJECTED', project_id: SecureRandom.uuid }, as: :turbo_stream
      post run_path(run, action: :accept, suggestion_id: suggestion.id), as: :turbo_stream
    end.to change { in_org { Ticket.count } }.by(1)
    ticket = in_org { suggestion.reload.created_ticket }
    expect(ticket.title).to eq(suggestion.title)
    expect(ticket.project_id).to eq(meeting.project_id)
    expect(in_org { meeting.outgoing_references.where(target: ticket).exists? }).to be true
    expect(response.body).to include("Ticket ##{ticket.number} angelegt", 'Ticket öffnen')
  end

  it 'keeps accepted state when dismissing from a stale meeting display' do
    run = finish_run(start_run)
    suggestion = in_org { run.meeting_ticket_suggestions.first }
    post run_path(run, action: :accept, suggestion_id: suggestion.id), as: :turbo_stream
    post dismiss_organisation_project_meeting_ticket_suggestion_path(organisation, project, meeting, suggestion), as: :turbo_stream
    expect(suggestion.reload).to be_accepted
    expect(in_org { Ticket.count }).to eq(1)
  end

  it 'dismisses without tickets and keeps the row in history' do
    run = finish_run(start_run)
    suggestion = in_org { run.meeting_ticket_suggestions.first }
    expect do
      2.times do
        # Each browser request is a separate N+1 scan; don't group two requests.
        Prosopite.finish
        Prosopite.scan
        post run_path(run, action: :dismiss, suggestion_id: suggestion.id), as: :turbo_stream
      end
      post run_path(run, action: :accept, suggestion_id: suggestion.id), as: :turbo_stream
    end.not_to(change { in_org { Ticket.count } })
    expect(suggestion.reload).to be_dismissed
    expect(response.body).to include('Verworfen')
  end

  it 'does not replace an old result with the next run and refuses superseded IDs' do
    first = finish_run(start_run)
    id = first.results.first['id']
    allow(provider).to receive(:chat).and_return(content: '[{"title":"Neuer Vorschlag"}]', token_usage: {}, model_used: 'test')
    finish_run(start_run)
    get run_path(first)
    expect(response.body).to include('Rechnung senden', 'Überholt')
    expect(response.body).not_to include('Neuer Vorschlag', 'Als Ticket anlegen')
    post run_path(first, action: :accept, suggestion_id: id), as: :turbo_stream
    expect(response).to have_http_status(:not_found)
    expect(in_org { Ticket.count }).to eq(0)
  end

  it 'checks the run/suggestion boundary even inside the same meeting' do
    first = finish_run(start_run)
    suggestion = first.meeting_ticket_suggestions.first
    suggestion.dismissed!
    second = finish_run(start_run)
    post run_path(second, action: :accept, suggestion_id: suggestion.id), as: :turbo_stream
    expect(response).to have_http_status(:not_found)
  end

  it 'denies foreign conversation access without disclosing the run' do
    run = finish_run(start_run)
    other = create(:user)
    create(:membership, user: other, organisation: organisation, role: user.memberships.find_by!(organisation: organisation).role, active: true)
    sign_in other
    get run_path(run)
    expect(response).not_to have_http_status(:ok)
    expect(response.body).not_to include('Rechnung senden')
  end

  it 'redacts results and target titles after meeting read access is revoked' do
    run = finish_run(start_run)
    access.update!(meetings_access: 'no_access')
    get run_path(run)
    expect(response.body).not_to include('Rechnung senden', 'Planungsrunde', project.name)
    expect(response.body).to include('keine Berechtigung')
    post run_path(run, action: :accept, suggestion_id: run.results.first['id']), as: :turbo_stream
    expect(in_org { Ticket.count }).to eq(0)
  end

  it 'requires both meeting and ticket writes for acceptance' do
    run = finish_run(start_run)
    access.update!(tickets_access: 'read_only')
    post run_path(run, action: :accept, suggestion_id: run.results.first['id']), as: :turbo_stream
    expect(response).to have_http_status(:forbidden)
    expect(in_org { Ticket.count }).to eq(0)
    get run_path(run)
    expect(response.body).not_to include('Als Ticket anlegen')
    expect(response.body).to include('Verwerfen')
  end

  it 'hides similar and created ticket titles and links when ticket access is withdrawn' do
    run = finish_run(start_run)
    suggestion = in_org { run.meeting_ticket_suggestions.first }
    post run_path(run, action: :accept, suggestion_id: suggestion.id), as: :turbo_stream
    ticket = in_org { suggestion.reload.created_ticket }
    in_org { run.meeting_ticket_suggestions.last.update!(similar_ticket: ticket) }
    in_org { access.update!(tickets_access: 'no_access') }
    get run_path(run)
    expect(response.body).not_to include('Ticket öffnen', 'Ähnliches Ticket', "ticket_id=#{ticket.id}")
  end

  it 'leaves failed ticket creation open for a successful retry' do
    run = finish_run(start_run)
    suggestion = in_org { run.meeting_ticket_suggestions.first }
    allow(Actors::SaveTicket).to receive(:call).and_return(Actors::BaseActor::Result.new(success: false, errors: ['Speichern fehlgeschlagen']))
    post run_path(run, action: :accept, suggestion_id: suggestion.id), as: :turbo_stream
    expect(suggestion.reload).to be_open
    expect(response.body).to include('Speichern fehlgeschlagen', 'Als Ticket anlegen')
  end

  it 'retries a failed task as a new attempt, preserving the old error and fixed target' do
    allow(provider).to receive(:chat).and_raise(StandardError, 'network')
    run = finish_run(start_run)
    chat.update!(scope_references: [])
    post run_path(run, action: :retry), as: :turbo_stream
    expect(response).to have_http_status(:ok)
    expect(in_org { MeetingTicketSuggestionRun.count }).to eq(2)
    expect(run.reload).to be_failed
    expect(in_org { MeetingTicketSuggestionRun.order(:created_at).last.meeting_id }).to eq(meeting.id)
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end
  it 'filters the target picker by organisation and current write permission' do
    other_org = create(:organisation)
    foreign = ActsAsTenant.with_tenant(other_org) { create(:meeting, organisation: other_org, title: 'Foreign private title') }
    get organisation_assistant_ticket_suggestion_meetings_path(organisation), params: { meeting_ids: [meeting.id, foreign.id] }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.pluck('id')).to eq([meeting.id])
    expect(response.body).not_to include('Foreign private title')
    in_org { access.update!(meetings_access: 'read_only') }
    get organisation_assistant_ticket_suggestion_meetings_path(organisation), params: { meeting_ids: [meeting.id] }, as: :json
    expect(response.parsed_body).to eq([])
  end

  it 'does not broadcast a first structured request and its meeting metadata' do
    expect(Turbo::StreamsChannel).not_to receive(:broadcast_append_to)
    post organisation_assistant_chats_path(organisation), params: {
      chat: { reference_keys: ["Meeting:#{meeting.id}"], chatposts_attributes: { '0' => { content: 'Leite Aufgaben ab.', ticket_suggestion_meeting_id: meeting.id } } }
    }, as: :turbo_stream
    expect(response).to have_http_status(:ok)
  end

  it 'rejects starts with read-only meeting access without enqueueing either paid job' do
    thread = chat
    access.update!(meetings_access: 'read_only')
    expect do
      post organisation_assistant_chat_chatposts_path(organisation, thread), params: { chatpost: { content: 'Generate', ticket_suggestion_meeting_id: meeting.id } }, as: :turbo_stream
    end.not_to(change { in_org { MeetingTicketSuggestionRun.count } })
    expect(Meetings::TicketSuggestionRunJob).not_to have_been_enqueued
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end

  it 'rejects dismiss and retry after write access is revoked' do
    run = finish_run(start_run)
    suggestion = run.meeting_ticket_suggestions.first
    access.update!(meetings_access: 'read_only')
    post run_path(run, action: :dismiss, suggestion_id: suggestion.id), as: :turbo_stream
    expect(response).to have_http_status(:forbidden)
    expect(suggestion.reload).to be_open
    run.update!(status: :failed)
    expect do
      post run_path(run, action: :retry), as: :turbo_stream
    end.not_to(change { in_org { MeetingTicketSuggestionRun.count } })
    expect(response).to have_http_status(:forbidden)
  end

  it 'consumes the retry once even after that new run finishes' do
    allow(provider).to receive(:chat).and_return(content: 'bad JSON', token_usage: {}, model_used: 'test')
    run = finish_run(start_run)
    post run_path(run, action: :retry), as: :turbo_stream
    expect(response.body).to include('bereits ein neuer Versuch')
    allow(provider).to receive(:chat).and_return(content: '[]', token_usage: {}, model_used: 'test')
    in_org { finish_run(MeetingTicketSuggestionRun.order(:created_at).last) }
    expect do
      post run_path(run, action: :retry), as: :turbo_stream
    end.not_to(change { in_org { MeetingTicketSuggestionRun.count } })
    expect(response).to have_http_status(:unprocessable_content)
    get run_path(run)
    expect(response.body).not_to include('Erneut versuchen')
  end

  it 'excludes archived projects from the picker and rejects forged starts' do
    thread = chat
    project.update!(archived_at: Time.current)
    get organisation_assistant_ticket_suggestion_meetings_path(organisation), params: { meeting_ids: [meeting.id] }, as: :json
    expect(response.parsed_body).to eq([])
    post organisation_assistant_chat_chatposts_path(organisation, thread), params: { chatpost: { content: 'Generate', ticket_suggestion_meeting_id: meeting.id } }, as: :turbo_stream
    expect(in_org { MeetingTicketSuggestionRun.count }).to eq(0)
    expect(Meetings::TicketSuggestionRunJob).not_to have_been_enqueued
  end

  it 'returns a readable matching frame for a deleted run' do
    run = finish_run(start_run)
    path = run_path(run)
    run.destroy!
    get path
    expect(response).to have_http_status(:not_found)
    expect(response.body).to include("meeting_ticket_suggestion_run_#{run.id}", 'keine Berechtigung')
  end

  it 'keeps the presentation digest stable across CSRF tokens but changes it with ticket rights' do
    run = finish_run(start_run)
    get run_path(run)
    first = Nokogiri::HTML(response.body).at_css('turbo-frame')['data-assistant-suggestion-result-digest-value']
    get run_path(run)
    expect(Nokogiri::HTML(response.body).at_css('turbo-frame')['data-assistant-suggestion-result-digest-value']).to eq(first)
    in_org { access.update!(tickets_access: 'read_only') }
    get run_path(run)
    expect(Nokogiri::HTML(response.body).at_css('turbo-frame')['data-assistant-suggestion-result-digest-value']).not_to eq(first)
    expect(response.body).to include('data-assistant-suggestion-result-active-value="false"')
  end

  it 'shows a hard-crashed queue delivery as retryable without waiting ten minutes' do
    ActiveJob::Base.queue_adapter = :solid_queue
    run = start_run
    queued = SolidQueue::Job.find_by!(active_job_id: run.job_id)
    run.update!(status: :running)
    queued.failed_with(StandardError.new('Worker killed'))
    get run_path(run)
    expect(response.body).to include('Erneut versuchen')
    expect(run.reload).to be_failed
    expect(meeting.reload.suggestions_creation_flag).to be false
    expect(provider).not_to have_received(:chat)
  end

  it 'shows source and result caps from the service limits on a completed card' do
    meeting.update!(notes: 'x' * (Meetings::AssistantSource::MAX_TEXT_CHARS + 1))
    allow(provider).to receive(:chat).and_return(content: Array.new(11) { { title: 'x' * 256, description: 'x' * 4001 } }.to_json, token_usage: {}, model_used: 'test')
    run = finish_run(start_run)
    get run_path(run)
    expect(response.body).to include('Quelle gekürzt', '8.000', 'Ergebnis gekürzt', '10 Vorschläge', '255', '4.000')
    expect(response.body).not_to include('Translation missing')
  end

  it 'preloads ticket hints again after a result action reloads the run' do
    run = finish_run(start_run)
    rows = run.meeting_ticket_suggestions.to_a
    rows.each_with_index do |row, index|
      row.update!(similar_ticket: create(:ticket, organisation: organisation, project: project, title: "Similar #{index}"))
    end
    post run_path(run, action: :dismiss, suggestion_id: rows.first.id), as: :turbo_stream
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Similar 0', 'Similar 1', 'Verworfen')
  end

  it 'announces linked-ticket refresh only after a successful accept' do
    run = finish_run(start_run)
    rows = run.meeting_ticket_suggestions.to_a

    post run_path(run, action: :dismiss, suggestion_id: rows.first.id), as: :turbo_stream
    expect(response.body).to include('data-assistant-suggestion-result-announce-links-value="false"')

    post run_path(run, action: :accept, suggestion_id: rows.last.id), as: :turbo_stream
    expect(response.body).to include('data-assistant-suggestion-result-announce-links-value="true"')
  end

  it 'denies acceptance after the meeting project is archived' do
    run = finish_run(start_run)
    in_org { project.update!(archived_at: Time.current) }
    expect do
      post run_path(run, action: :accept, suggestion_id: run.results.first['id']), as: :turbo_stream
    end.not_to(change { in_org { Ticket.count } })
    expect(response).to have_http_status(:forbidden)
    expect(in_org { run.meeting_ticket_suggestions.first }).to be_open
    expect(in_org { meeting.outgoing_references.where(target_type: 'Ticket') }).not_to exist
    get run_path(run)
    expect(response.body).not_to include('Als Ticket anlegen')
  end

  it 'clears transient acceptance errors on explicit status refresh' do
    run = finish_run(start_run)
    allow(Actors::SaveTicket).to receive(:call).and_return(Actors::BaseActor::Result.new(success: false, errors: ['Temporary save error']))
    post run_path(run, action: :accept, suggestion_id: run.results.first['id']), as: :turbo_stream
    failed = Nokogiri::HTML(response.body).at_css('turbo-frame')
    expect(failed.text).to include('Temporary save error')
    get run_path(run)
    fresh = Nokogiri::HTML(response.body).at_css('turbo-frame')
    expect(fresh.text).not_to include('Temporary save error')
    expect(fresh['data-assistant-suggestion-result-digest-value']).not_to eq(failed['data-assistant-suggestion-result-digest-value'])
  end

  it 'keeps the frame target when a deleted run receives a Turbo action' do
    run = finish_run(start_run)
    path = run_path(run, action: :accept, suggestion_id: run.results.first['id'])
    run.destroy!
    post path, as: :turbo_stream
    expect(response).to have_http_status(:not_found)
    fragment = Nokogiri::HTML(response.body)
    expect(fragment.at_css("turbo-stream template turbo-frame[id='meeting_ticket_suggestion_run_#{run.id}']")).to be_present
  end

  it 'renders enqueue failures on the meeting page as an error instead of silently removing the spinner' do
    allow_any_instance_of(Meetings::TicketSuggestionRunJob).to receive(:enqueue).and_return(false)
    result = Actors::StartTicketSuggestionRun.call(meeting: meeting, current_user: user)
    expect(result).to be_success
    get organisation_project_meeting_path(organisation, project, meeting)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(result.resource.error)
    expect(result.resource.error).to be_present
  end

  %i[show index].each do |surface|
    it "recovers a hard-crashed meeting-page run through the real #{surface} request" do
      ActiveJob::Base.queue_adapter = :solid_queue
      result = Actors::StartTicketSuggestionRun.call(meeting: meeting, current_user: user)
      run = result.resource
      run.update!(status: :running)
      SolidQueue::Job.find_by!(active_job_id: run.job_id).failed_with(StandardError.new('Worker killed'))
      path = surface == :show ? organisation_project_meeting_path(organisation, project, meeting) : organisation_project_meetings_path(organisation, project, meeting_id: meeting.id)
      get path
      expect(response).to have_http_status(:ok)
      expect(run.reload).to be_failed
      expect(response.body).to include(run.error)
      expect(meeting.reload.suggestions_creation_flag).to be false
      expect(meeting.suggestions_creation_error).to eq(run.error)
      expect(provider).not_to have_received(:chat)
    end
  end
end
