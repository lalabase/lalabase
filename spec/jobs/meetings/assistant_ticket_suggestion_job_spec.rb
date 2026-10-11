# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Bound meeting task jobs', type: :job do
  include_context 'assistant ticket suggestions'
  include ActiveSupport::Testing::TimeHelpers

  # These examples simulate separate worker invocations within a single example.
  before { Prosopite.pause }
  after { Prosopite.resume }

  it 'uses both bounded meeting sources and the explicit instruction, without personal history or other references' do
    chat.chatposts.first.update!(content: 'PRIVATE HISTORY SECRET')
    other = create(:meeting, organisation: organisation, project: project, creator: user, notes: 'OTHER SOURCE SECRET')
    chat.update!(scope_references: chat.scope_references + [{ type: 'Meeting', id: other.id }])
    meeting.update!(notes: "---\nprivate_metadata: SECRET\n---\nNotizen: Rechnung senden. #{'x' * 9000}")
    run = start_run(instruction: 'Priorisiere Rechnungen.')
    finish_run(run)
    expect(run).to be_succeeded
    expect(provider).to have_received(:chat) do |args|
      payload = args[:messages].to_json
      expect(payload).to include('Rechnung senden', 'Angebot prüfen', 'Priorisiere Rechnungen.')
      expect(payload).not_to include('PRIVATE HISTORY', 'OTHER SOURCE', 'LATER EDIT', 'LATER TRANSCRIPT', 'private_metadata')
    end
    expect(run.source_truncated?).to be true
    expect(run.results.size).to eq(2)
    expect(Ticket.count).to eq(0)
  end

  it 'claims a queued job once, including duplicate delivery after successful completion' do
    run = start_run
    2.times { finish_run(run) }
    expect(provider).to have_received(:chat).once
    expect(Lalabase::Llm::UsageTracking).to have_received(:record).once
    expect(MeetingTicketSuggestion.count).to eq(2)
  end

  it 'marks an interrupted delivery immediately retryable without billing again' do
    run = start_run
    run.update!(status: :running)
    finish_run(run)
    expect(provider).not_to have_received(:chat)
    expect(run).to be_failed
    expect(run).to be_retryable
    expect(meeting.reload.suggestions_creation_flag).to be false
  end

  it 'rejects a second start before it creates another question or job' do
    start_run
    expect do
      result = Actors::CreateChatpost.call(chat: chat, current_user: user, params: { content: 'again', ticket_suggestion_meeting_id: meeting.id })
      expect(result).not_to be_success
    end.not_to change(Chatpost, :count)
    expect(MeetingTicketSuggestionRun.count).to eq(1)
  end

  it 'records a successful empty result' do
    allow(provider).to receive(:chat).and_return(content: '[]', token_usage: {}, model_used: 'test')
    run = finish_run(start_run)
    expect(run).to be_succeeded
    expect(run.results).to eq([])
    expect(meeting.reload.suggestions_creation_flag).to be false
  end

  it 'records malformed JSON as a failure and preserves existing proposals' do
    old = create(:meeting_ticket_suggestion, meeting: meeting)
    allow(provider).to receive(:chat).and_return(content: 'Not JSON', token_usage: {}, model_used: 'test')
    run = finish_run(start_run)
    expect(run).to be_failed
    expect(run.error).to be_present
    expect(old.reload).to be_open
  end

  it 'records result caps and ignores injected identities' do
    raw = Array.new(12) { { title: 'T' * 300, description: 'D' * 4100, similar_ticket_id: SecureRandom.uuid } }
    allow(provider).to receive(:chat).and_return(content: raw.to_json, token_usage: {}, model_used: 'test')
    run = finish_run(start_run)
    expect(run).to be_result_truncated
    expect(run.results.size).to eq(10)
    expect(run.meeting_ticket_suggestions.first).to have_attributes(title: 'T' * 255, description: 'D' * 4000, similar_ticket_id: nil)
  end

  it 'checks rights before paying for a queued task' do
    run = start_run
    access.update!(meetings_access: 'read_only')
    finish_run(run)
    expect(run).to be_failed
    expect(provider).not_to have_received(:chat)
  end

  it 'checks rights again before publishing the result' do
    run = start_run
    allow(provider).to receive(:chat) do
      access.update!(meetings_access: 'read_only')
      { content: '[{"title":"No longer allowed"}]', token_usage: {}, model_used: 'test' }
    end
    finish_run(run)
    expect(run).to be_failed
    expect(MeetingTicketSuggestion.count).to eq(0)
  end

  it 'keeps an expired worker from replacing a newer result' do
    old = start_run
    current = nil
    allow(provider).to receive(:chat) do
      old.update!(updated_at: 1.hour.ago)
      current = start_run
      allow(provider).to receive(:chat).and_return(content: '[{"title":"Current"}]', token_usage: {}, model_used: 'test')
      finish_run(current)
      { content: '[{"title":"Expired"}]', token_usage: {}, model_used: 'test' }
    end
    finish_run(old)
    expect(current.reload).to be_succeeded
    expect(old.reload).to be_failed
    expect(MeetingTicketSuggestion.pluck(:title, :meeting_ticket_suggestion_run_id)).to eq([['Current', current.id]])
  end

  it 'does not leak results through chat broadcasts' do
    chat
    expect(Turbo::StreamsChannel).not_to receive(:broadcast_append_to)
    expect(Turbo::StreamsChannel).not_to receive(:broadcast_replace_to)
    run = start_run
    finish_run(run)
    run.chatpost.reload.update!(content: 'Updated task instruction')
  end

  it 'retains the meeting result when its personal conversation is deleted' do
    run = finish_run(start_run)
    result_ids = run.meeting_ticket_suggestion_ids
    chat.destroy!
    expect(MeetingTicketSuggestionRun.where(id: run.id)).not_to exist
    expect(MeetingTicketSuggestion.where(id: result_ids).pluck(:meeting_ticket_suggestion_run_id)).to eq([nil, nil])
  end

  it 'does not let a delayed legacy job replace a bound attempt' do
    run = start_run
    Meetings::TicketSuggestionJob.perform_now(meeting_id: meeting.id)
    expect(run.reload).to be_queued
    expect(provider).not_to have_received(:chat)
  end

  it 'never interprets an unbound new job as a legacy generation' do
    Meetings::TicketSuggestionRunJob.perform_now(meeting_id: meeting.id)
    expect(provider).not_to have_received(:chat)
    expect(MeetingTicketSuggestion.count).to eq(0)
  end

  it 'stores source fingerprints and refuses changed source material before the provider call' do
    run = start_run
    expect(run.sources.to_json).not_to include('Rechnung senden', 'Angebot prüfen', '"text":')
    expect(run.sources['notes']['sha256']).to be_present
    meeting.update!(transcript: 'Redacted')
    finish_run(run)
    expect(run).to be_failed
    expect(provider).not_to have_received(:chat)
  end

  it 'checks source fingerprints again before publication' do
    run = start_run
    allow(provider).to receive(:chat) do
      meeting.update!(notes: 'Redacted during generation')
      { content: '[{"title":"Stale confidential source"}]', token_usage: {}, model_used: 'test' }
    end
    finish_run(run)
    expect(run).to be_failed
    expect(MeetingTicketSuggestion.count).to eq(0)
  end

  it 'does not publish assistant errors on the shared meeting' do
    allow(provider).to receive(:chat).and_raise(StandardError, 'Private failure')
    run = finish_run(start_run)
    expect(run.error).to be_present
    expect(meeting.reload.suggestions_creation_error).to be_blank
  end

  it 'completes a meeting-page run through the actual Solid Queue serialization' do
    ActiveJob::Base.queue_adapter = :solid_queue
    result = Actors::StartTicketSuggestionRun.call(meeting: meeting, current_user: user)
    expect(result).to be_success
    run = result.resource
    expect(run.sources).to eq({})
    queued = SolidQueue::Job.find_by!(active_job_id: run.job_id)
    execute_suggestion_payload(queued.arguments)
    expect(run.reload).to be_succeeded
    expect(run.meeting_ticket_suggestions.count).to eq(2)
    expect(meeting.reload.suggestions_creation_flag).to be false
    expect(provider).to have_received(:chat) do |args|
      expect(args[:messages].to_json).to include('Mitschrift: Angebot prüfen.')
    end
  end

  it 'preserves a newer run when an already executing legacy job finally returns' do
    current = nil
    allow(provider).to receive(:chat) do
      current = start_run
      allow(provider).to receive(:chat).and_return(content: '[{"title":"New"}]', token_usage: {}, model_used: 'test')
      finish_run(current)
      { content: '[{"title":"Legacy"}]', token_usage: {}, model_used: 'test' }
    end
    Meetings::TicketSuggestionJob.perform_now(meeting_id: meeting.id)
    expect(MeetingTicketSuggestion.pluck(:title, :meeting_ticket_suggestion_run_id)).to eq([['New', current.id]])
  end

  it 'keeps enqueue exceptions and rejected enqueues as retryable failures' do
    [false, ActiveJob::EnqueueError.new('queue down')].each do |failure|
      allow_any_instance_of(Meetings::TicketSuggestionRunJob).to receive(:enqueue) do
        raise failure if failure.is_a?(Exception)

        failure
      end
      run = start_run
      expect(run.reload).to be_failed
      expect(run).to be_retryable
      expect(meeting.reload.suggestions_creation_flag).to be false
    end
    expect(provider).not_to have_received(:chat)
  end

  it 'excludes structured tasks from normal response execution, history and legacy question selection' do
    ordinary = chat.chatposts.first
    ordinary.update!(content: 'Ordinary personal question')
    run = start_run(instruction: 'STRUCTURED TASK ONLY')
    job = ChatResponseJob.new
    expect(job).not_to receive(:resolve_provider)
    expect { job.perform(chat, question_chatpost_id: run.chatpost_id, acting_user_id: user.id) }.not_to change(Chatpost, :count)
    allow(job).to receive(:system_prompt_with_context).and_return('System')
    expect(job.send(:build_messages, chat).map { |message| message[:content] }).to include(ordinary.content)
    expect(job.send(:build_messages, chat).map { |message| message[:content] }).not_to include(run.instruction)
    expect(job.send(:last_non_assistant_post, chat)).to eq(ordinary)
  end

  it 'handles Solid Queue release and redelivery with the original job identity' do
    ActiveJob::Base.queue_adapter = :solid_queue
    run = start_run
    queued = SolidQueue::Job.find_by!(active_job_id: run.job_id)
    process = SolidQueue::Process.create!(kind: 'Worker', name: SecureRandom.uuid, pid: Process.pid, hostname: 'test', last_heartbeat_at: Time.current)
    queued.ready_execution.destroy!
    claim = SolidQueue::ClaimedExecution.create!(job: queued, process: process)
    run.update!(status: :running)
    claim.release
    expect(queued.reload.ready_execution).to be_present
    execute_suggestion_payload(queued.arguments)
    expect(run.reload).to be_failed
    expect(run).to be_retryable
    expect(provider).not_to have_received(:chat)
  end

  %i[enqueue interrupted recovered provider].each do |failure|
    it "keeps a visible meeting-page error after #{failure}" do
      allow_any_instance_of(Meetings::TicketSuggestionRunJob).to receive(:enqueue).and_return(false) if failure == :enqueue
      result = Actors::StartTicketSuggestionRun.call(meeting: meeting, current_user: user)
      expect(result).to be_success
      run = result.resource
      case failure
      when :interrupted
        run.update!(status: :running)
        finish_run(run)
      when :recovered
        run.update!(status: :running)
        queued = SolidQueue::Job.create!(active_job_id: run.job_id, class_name: 'Meetings::TicketSuggestionRunJob', queue_name: 'default', arguments: {})
        queued.failed_with(StandardError.new('Worker killed'))
        run.recover_failed_delivery!
      when :provider
        allow(provider).to receive(:chat).and_raise(StandardError, 'Provider failed')
        finish_run(run)
      end
      expect(run.reload).to be_failed
      expect(meeting.reload.suggestions_creation_flag).to be false
      expect(meeting.suggestions_creation_error).to eq(run.error)
      expect(meeting.suggestions_creation_error).to be_present
    end
  end

  it 'expires a run only after the ten-minute boundary and then permits a new attempt' do
    freeze_time do
      run = start_run
      travel Meeting::SUGGESTIONS_STALE_AFTER
      expect(run.reload).not_to be_stale
      result = Actors::CreateChatpost.call(chat: chat, current_user: user, params: { content: 'Again', ticket_suggestion_meeting_id: meeting.id })
      expect(result).not_to be_success
      travel 1.second
      expect(run.reload).to be_stale
      current = start_run
      expect(current).to be_queued
      expect(run.reload).to be_failed
    end
  end
end
