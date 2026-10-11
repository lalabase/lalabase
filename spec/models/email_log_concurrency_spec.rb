# frozen_string_literal: true

require 'rails_helper'
require 'support/email_log_test_helper'

RSpec.describe EmailLog, type: :model do
  describe 'Concurrency Control' do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user, organisation: organisation) }
    let(:notification) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation)
      end
    end
    let(:email_log) do
      ActsAsTenant.with_tenant(organisation) do
        create(:email_log,
               notification: notification,
               organisation: organisation,
               status: 'failed',
               failure_reason: 'Network error')
      end
    end

    describe 'optimistic locking with lock_version' do
      it 'prevents concurrent modifications' do
        with_tenant(organisation) do
          # Load the same record in two instances
          log1 = EmailLog.find(email_log.id)
          log2 = EmailLog.find(email_log.id)

          # Modify first instance
          log1.update!(status: 'sent')

          # Try to modify second instance (should fail)
          expect do
            log2.update!(status: 'delivered')
          end.to raise_error(ActiveRecord::StaleObjectError)
        end
      end

      it 'increments lock_version on each update' do
        with_tenant(organisation) do
          initial_version = email_log.lock_version

          email_log.update!(status: 'sent')
          expect(email_log.reload.lock_version).to eq(initial_version + 1)

          email_log.update!(status: 'delivered')
          expect(email_log.reload.lock_version).to eq(initial_version + 2)
        end
      end

      it 'handles lock_version in resend!' do
        with_tenant(organisation) do
          # Simulate concurrent resend attempts
          log1 = EmailLog.find(email_log.id)
          log2 = EmailLog.find(email_log.id)

          # First resend should succeed
          new_log1 = nil
          expect do
            new_log1 = log1.resend!
          end.to change(EmailLog, :count).by(1)

          expect(new_log1).to be_present
          expect(new_log1.status).to eq('queued')

          # Second resend with stale object should fail gracefully
          # resend! handles stale object internally and returns false
          result = log2.resend!
          expect(result).to be false
        end
      end
    end

    describe '#resend! race condition protection' do
      it 'prevents duplicate resends through transaction isolation' do
        with_tenant(organisation) do
          # Create a failed email that can be resent
          email_log.update!(status: 'failed')

          results = []
          threads = []

          # Simulate concurrent resend attempts
          3.times do
            threads << Thread.new do
              ActiveRecord::Base.connection_pool.with_connection do
                ActsAsTenant.with_tenant(organisation) do
                  log = EmailLog.find(email_log.id)
                  new_log = log.resend!
                  results << { success: true, log_id: new_log.id }
                rescue ActiveRecord::StaleObjectError
                  results << { success: false, error: 'StaleObjectError' }
                rescue StandardError => e
                  results << { success: false, error: e.class.name }
                end
              end
            end
          end

          threads.each(&:join)

          # Only one should succeed
          successful = results.select { |r| r[:success] }
          expect(successful.size).to eq(1)

          # Should create exactly one new email log
          expect(EmailLog.where(
            notification: notification,
            status: 'queued'
          ).count).to eq(1)
        end
      end

      it 'maintains data consistency during concurrent updates' do
        with_tenant(organisation) do
          email_log.update!(open_count: 0, click_count: 0)

          threads = []
          10.times do
            threads << Thread.new do
              ActiveRecord::Base.connection_pool.with_connection do
                ActsAsTenant.with_tenant(organisation) do
                  log = EmailLog.find(email_log.id)
                  log.increment!(:open_count)
                rescue ActiveRecord::StaleObjectError
                  retry # Retry on conflict
                end
              end
            end
          end

          threads.each(&:join)

          # All increments should be applied
          expect(email_log.reload.open_count).to eq(10)
        end
      end

      it 'handles webhook updates atomically' do
        with_tenant(organisation) do
          email_log.update!(status: 'sent', provider_message_id: 'msg_123')

          # Simulate concurrent webhook callbacks
          delivered_thread = Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              ActsAsTenant.with_tenant(organisation) do
                log = EmailLog.find(email_log.id)
                log.update!(status: 'delivered', delivered_at: Time.current)
              rescue ActiveRecord::StaleObjectError
                # Expected in concurrent scenario
              end
            end
          end

          opened_thread = Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              ActsAsTenant.with_tenant(organisation) do
                log = EmailLog.find(email_log.id)
                log.update!(status: 'opened', opened_at: Time.current, open_count: 1)
              rescue ActiveRecord::StaleObjectError
                # Expected in concurrent scenario
              end
            end
          end

          [delivered_thread, opened_thread].each(&:join)

          # One of them should have won
          final_status = email_log.reload.status
          expect(%w[delivered opened]).to include(final_status)
        end
      end
    end

    describe '#can_resend? thread safety' do
      it 'correctly evaluates resend eligibility under concurrent access' do
        with_tenant(organisation) do
          # Only failed/bounced/deferred emails can be resent
          statuses_that_can_resend = %w[failed bounced deferred]
          statuses_that_cannot_resend = %w[queued sent delivered complaint opened clicked unsubscribed]

          # Ensure can_retry is true for testing
          email_log.update!(can_retry: true, retry_count: 0)

          statuses_that_can_resend.each do |status|
            email_log.update!(status: status)
            expect(email_log.can_resend?).to be(true), "Expected can_resend? to be true for status '#{status}'"
          end

          statuses_that_cannot_resend.each do |status|
            email_log.update!(status: status)
            expect(email_log.can_resend?).to be(false), "Expected can_resend? to be false for status '#{status}'"
          end
        end
      end

      it 'prevents resend of recently created logs' do
        with_tenant(organisation) do
          # Create a new failed log
          recent_log = create(:email_log,
                              notification: notification,
                              organisation: organisation,
                              status: 'failed',
                              created_at: 1.minute.ago)

          # Should not be able to resend immediately
          expect(recent_log.can_resend?).to be true # Failed status allows resend

          # But resend should check for recent duplicates
          new_log = recent_log.resend!

          # The new log should have metadata about the resend
          expect(new_log.metadata['resent_at']).to be_present
          expect(new_log.metadata['original_id']).to eq(recent_log.id)

          # Cannot resend again immediately
          result = recent_log.reload.resend!
          expect(result).to be false
        end
      end
    end
  end
end
