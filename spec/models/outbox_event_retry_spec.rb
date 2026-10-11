# frozen_string_literal: true

require 'rails_helper'

RSpec.describe OutboxEvent, '#mark_failed retry behavior' do
  let(:organisation) { create(:organisation) }
  let(:event) do
    ActsAsTenant.with_tenant(organisation) do
      create(:outbox_event, organisation: organisation, retry_count: 0)
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    # Prevent actual job scheduling during tests
    allow(OutboxConsumeJob).to receive_message_chain(:set, :perform_later)
  end

  describe '#mark_failed increments retry_count exactly once' do
    it 'increments retry_count by 1 (not 2) on failure' do
      expect { event.mark_failed('something broke') }
        .to change { event.reload.retry_count }.from(0).to(1)
    end

    it 'reaches MAX_RETRY_COUNT after exactly 10 consecutive failures' do
      Prosopite.pause
      OutboxEvent::MAX_RETRY_COUNT.times do |i|
        event.mark_failed("failure ##{i + 1}")
        event.reload
      end
      Prosopite.resume

      expect(event.retry_count).to eq(OutboxEvent::MAX_RETRY_COUNT)
      expect(event.can_retry?).to be false
    end

    it 'uses the correct first retry delay (RETRY_DELAYS[0])' do
      before_mark = Time.current
      event.mark_failed('first failure')
      event.reload

      expected_min = before_mark + OutboxEvent::RETRY_DELAYS[0]
      expect(event.available_at).to be_within(2.seconds).of(expected_min),
                                    "First retry should use RETRY_DELAYS[0] = #{OutboxEvent::RETRY_DELAYS[0].inspect}, " \
                                    'not RETRY_DELAYS[1] (which would indicate double-increment bug)'
    end

    it 'uses RETRY_DELAYS[1] on second failure, not RETRY_DELAYS[3]' do
      event.mark_failed('failure 1')
      event.reload

      before_mark = Time.current
      event.mark_failed('failure 2')
      event.reload

      expected_min = before_mark + OutboxEvent::RETRY_DELAYS[1]
      expect(event.available_at).to be_within(2.seconds).of(expected_min)
    end
  end

  describe '#mark_failed schedules retry when possible' do
    it 'schedules a new processing job on failure' do
      expect(OutboxConsumeJob).to receive_message_chain(:set, :perform_later)
      event.mark_failed('transient error')
    end

    it 'does not schedule a job when max retries exhausted' do
      event.update!(retry_count: OutboxEvent::MAX_RETRY_COUNT)

      expect(OutboxConsumeJob).not_to receive(:set)
      event.mark_failed('final failure')
    end

    it 'preserves error_message when max retries exhausted' do
      event.update!(retry_count: OutboxEvent::MAX_RETRY_COUNT)
      event.mark_failed('permanent failure')

      expect(event.reload.error_message).to eq('permanent failure')
    end
  end

  describe '#retry! called independently (via retry_failed)' do
    before do
      event.update!(retry_count: 3, error_message: 'previous error')
    end

    it 'increments retry_count by 1' do
      expect { event.retry! }
        .to change { event.reload.retry_count }.from(3).to(4)
    end

    it 'clears error_message' do
      event.retry!
      expect(event.reload.error_message).to be_nil
    end

    it 'does nothing when max retries reached' do
      event.update!(retry_count: OutboxEvent::MAX_RETRY_COUNT)

      expect { event.retry! }.not_to(change { event.reload.retry_count })
    end
  end
end
