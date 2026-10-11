# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Ticket suggestion concurrency' do
  self.use_transactional_tests = false
  # Separate connections must see committed fixtures; restore the usual cleaner afterwards.
  before do
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.start
    Prosopite.pause
  end
  after { Prosopite.resume }
  include_context 'assistant ticket suggestions'

  def race(*actions)
    ready = Queue.new
    start = Queue.new
    workers = actions.map do |action|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActsAsTenant.with_tenant(organisation) do
            ready << true
            start.pop
            action.call
          end
        end
      end
    end
    actions.size.times { ready.pop }
    actions.size.times { start << true }
    workers.map do |worker|
      raise 'Concurrent operation did not finish' unless worker.join(15)

      worker.value
    end
  ensure
    workers&.each { |worker| worker.kill if worker.alive? }
  end

  it 'serializes simultaneous starts from two surfaces' do
    target_id = meeting.id
    chat_id = chat.id
    outcomes = race(
      -> { Actors::StartTicketSuggestionRun.call(meeting: Meeting.find(target_id), current_user: user) },
      -> { Actors::CreateChatpost.call(chat: Chat.find(chat_id), current_user: user, params: { content: 'Aufgaben', ticket_suggestion_meeting_id: target_id }) }
    )
    expect(outcomes.count(&:success?)).to eq(1)
    expect(MeetingTicketSuggestionRun.count).to eq(1)
  end

  it 'creates exactly one linked ticket for concurrent accept requests' do
    run = finish_run(start_run)
    id = run.meeting_ticket_suggestions.first.id
    accept = -> { Actors::AcceptTicketSuggestion.call(meeting: Meeting.find(meeting.id), suggestion: MeetingTicketSuggestion.find(id), current_user: user) }
    results = race(accept, accept)
    expect(results.count(&:success?)).to eq(1)
    expect(Ticket.count).to eq(1)
    expect(meeting.outgoing_references.where(target: Ticket.last)).to exist
    expect(MeetingTicketSuggestion.find(id)).to be_accepted
  end

  it 'lets only one of accept and dismiss win' do
    run = finish_run(start_run)
    id = run.meeting_ticket_suggestions.first.id
    race(
      -> { Actors::AcceptTicketSuggestion.call(meeting: Meeting.find(meeting.id), suggestion: MeetingTicketSuggestion.find(id), current_user: user) },
      -> { MeetingTicketSuggestion.open.where(id: id).update_all(status: MeetingTicketSuggestion.statuses[:dismissed], updated_at: Time.current) }
    )
    row = MeetingTicketSuggestion.find(id)
    expect(row).not_to be_open
    expect(Ticket.count).to eq(row.accepted? ? 1 : 0)
    expect(row.created_ticket_id.present?).to eq(row.accepted?)
  end

  it 'preserves accepted history or supersedes the unclaimed proposal during regeneration' do
    run = finish_run(start_run)
    suggestion = run.meeting_ticket_suggestions.first
    id = suggestion.id
    original_results = run.results.deep_dup
    next_run = start_run
    next_run.update!(status: :running)
    outcomes = race(
      -> { Actors::AcceptTicketSuggestion.call(meeting: Meeting.find(meeting.id), suggestion: suggestion, current_user: user) },
      -> { Meetings::TicketSuggestionService.new(meeting: Meeting.find(meeting.id), run: next_run).send(:persist_run, [{ title: 'New', description: 'New task' }]) }
    )
    expect(Ticket.count).to eq(outcomes.first.success? ? 1 : 0)
    old = MeetingTicketSuggestion.find_by(id: id)
    if old
      expect(old).to be_accepted
      expect(meeting.outgoing_references.where(target: old.created_ticket)).to exist
    end
    expect(run.reload.results).to eq(original_results)
    expect(meeting.meeting_ticket_suggestions.open.pluck(:title)).to eq(['New'])
  end

  it 'does not interrupt or pay twice while another worker holds the execution lock' do
    run = start_run
    payload = ActiveJob::Base.queue_adapter.enqueued_jobs.find { |job| job['job_id'] == run.job_id }
    entered = Queue.new
    release = Queue.new
    allow(provider).to receive(:chat) do
      entered << true
      release.pop
      { content: '[{"title":"Only once"}]', token_usage: {}, model_used: 'test' }
    end
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { ActiveJob::Base.execute(payload) }
    end
    Timeout.timeout(10) { entered.pop }
    execute_suggestion_payload(payload)
    expect(run.reload).to be_running
    release << true
    expect(worker.join(10)).to be_present
    worker.value
    expect(run.reload).to be_succeeded
    expect(provider).to have_received(:chat).once
    expect(MeetingTicketSuggestion.pluck(:title)).to eq(['Only once'])
  ensure
    release << true if release
    worker&.join(2)
    worker&.kill if worker&.alive?
  end
end
