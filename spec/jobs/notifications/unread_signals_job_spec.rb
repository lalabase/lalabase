# frozen_string_literal: true

require 'rails_helper'

# Runs for one user are serialised (limits_concurrency), so an older run cannot
# broadcast a stale dot after a newer one. Exercise the real queue as well as
# the key: a correct key alone does not prevent parallel or discarded runs.
RSpec.describe Notifications::UnreadSignalsJob, :ci_guard do
  it 'keys its concurrency limit by user' do
    expect(described_class.new(user_id: 'u-1').concurrency_key).to end_with('u-1')
    expect(described_class.new(user_id: 'u-1').concurrency_key)
      .not_to eq(described_class.new(user_id: 'u-2').concurrency_key)
  end

  it 'refreshes the signal of the user' do
    user = create(:user)
    allow(Notifications::UnreadSignals).to receive(:call)

    described_class.perform_now(user_id: user.id)

    expect(Notifications::UnreadSignals).to have_received(:call).with(user: user)
  end

  it 'does nothing for a user that no longer exists' do
    allow(Notifications::UnreadSignals).to receive(:call)

    described_class.perform_now(user_id: SecureRandom.uuid)

    expect(Notifications::UnreadSignals).not_to have_received(:call)
  end

  describe 'queue concurrency' do
    around do |example|
      previous_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :solid_queue
      example.run
    ensure
      ActiveJob::Base.queue_adapter = previous_adapter
    end

    # Repeated queue/semaphore queries are the behavior under test, not an
    # application N+1. Keep this exemption local to the real-adapter examples.
    before { Prosopite.pause }
    after { Prosopite.resume }

    let(:queued_jobs) { SolidQueue::Job.where(class_name: described_class.name) }

    it 'keeps a second refresh for the same user blocked until the first finishes' do
      user_id = SecureRandom.uuid
      first = described_class.perform_later(user_id: user_id)
      second = described_class.perform_later(user_id: user_id)

      expect(queued_jobs.pluck(:active_job_id)).to contain_exactly(first.job_id, second.job_id)
      expect(SolidQueue::ReadyExecution.where(job_id: queued_jobs.select(:id)).pluck(:job_id))
        .to contain_exactly(first.provider_job_id)
      expect(SolidQueue::BlockedExecution.where(job_id: queued_jobs.select(:id)).pluck(:job_id))
        .to contain_exactly(second.provider_job_id)
    end

    it 'lets different users refresh independently' do
      first = described_class.perform_later(user_id: SecureRandom.uuid)
      second = described_class.perform_later(user_id: SecureRandom.uuid)

      expect(SolidQueue::ReadyExecution.where(job_id: queued_jobs.select(:id)).pluck(:job_id))
        .to contain_exactly(first.provider_job_id, second.provider_job_id)
      expect(SolidQueue::BlockedExecution.where(job_id: queued_jobs.select(:id))).not_to exist
    end
  end
end
