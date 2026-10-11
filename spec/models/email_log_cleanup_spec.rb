# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmailLog, '.cleanup_old_logs', type: :model do
  let(:organisation) { create(:organisation) }

  def create_log(created_at:, metadata: { 'provider' => 'test' })
    ActsAsTenant.with_tenant(organisation) do
      notification = create(:notification, organisation: organisation)
      log = create(:email_log, :sent, notification: notification, organisation: organisation, metadata: metadata)
      log.update_columns(created_at: created_at, updated_at: created_at)
      log
    end
  end

  it 'archives logs older than the specified days, not newer ones' do
    recent_log = create_log(created_at: 5.days.ago)
    old_log    = create_log(created_at: 60.days.ago)

    ActsAsTenant.with_tenant(organisation) do
      EmailLog.cleanup_old_logs(days: 30)
    end

    recent_log.reload
    old_log.reload

    expect(recent_log.metadata).to include('provider' => 'test')
    expect(old_log.metadata).to include('archived' => true)
  end

  it 'hard-deletes logs older than 365 days' do
    ancient_log = create_log(created_at: 400.days.ago)

    ActsAsTenant.with_tenant(organisation) do
      EmailLog.cleanup_old_logs(days: 30)
      expect(EmailLog.where(id: ancient_log.id)).not_to exist
    end
  end

  it 'does not archive logs that will be deleted anyway (> 365 days)' do
    # Logs older than 365 days should be deleted, not archived first
    create_log(created_at: 400.days.ago)

    expect_any_instance_of(EmailLog).not_to receive(:update!)

    ActsAsTenant.with_tenant(organisation) do
      EmailLog.cleanup_old_logs(days: 30)
    end
  end
end
