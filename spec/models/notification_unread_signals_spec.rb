# frozen_string_literal: true

require 'rails_helper'

# Every change to an unread in-app notification refreshes the org
# switcher signal (Notifications::UnreadSignals): the callback covers every
# writer that saves a record (fanout, grouping, mark_as_read!, archive!, API,
# MCP); bulk writers go through Notification.bulk_transition!.
RSpec.describe Notification, 'org switcher signal', :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before do
    ActiveJob::Base.queue_adapter = :test
    ActsAsTenant.current_tenant = organisation
  end

  def build_signal(**attrs)
    build(:notification, recipient: user, organisation: organisation, project: nil,
                         event_type: 'mention', channel: 'in_app', state: :delivered, **attrs)
  end

  def signal_jobs
    enqueued_jobs.select { |job| job['job_class'] == 'Notifications::UnreadSignalsJob' }
  end

  it 'refreshes when a mention is created' do
    expect { build_signal.save! }.to have_enqueued_job(Notifications::UnreadSignalsJob).with(user_id: user.id)
  end

  it 'refreshes when an assignment is created' do
    expect { build_signal(event_type: 'ticket_assigned').save! }
      .to have_enqueued_job(Notifications::UnreadSignalsJob).with(user_id: user.id)
  end

  it 'refreshes on mark_as_read!, archive! and mark_as_unread!' do
    notification = build_signal.tap(&:save!)
    clear_enqueued_jobs

    notification.mark_as_read!
    notification.mark_as_unread!
    notification.archive!

    expect(signal_jobs.size).to eq(3)
  end

  it 'refreshes when an unread mention is destroyed' do
    notification = build_signal.tap(&:save!)
    clear_enqueued_jobs

    expect { notification.destroy! }.to have_enqueued_job(Notifications::UnreadSignalsJob)
  end

  it 'does not refresh when a non-state attribute changes' do
    notification = build_signal.tap(&:save!)
    clear_enqueued_jobs

    notification.update!(priority: :high)

    expect(signal_jobs).to be_empty
  end

  it 'refreshes for every other event type too, like the inbox count' do
    expect { build_signal(event_type: 'ticket_commented').save! }
      .to have_enqueued_job(Notifications::UnreadSignalsJob).with(user_id: user.id)
  end

  it 'does not refresh for email notifications' do
    build_signal(channel: 'email').save!

    expect(signal_jobs).to be_empty
  end

  # after_commit alone sees only the last save's changes; the fanout saves
  # inside OutboxEvent#process!'s transaction.
  it 'refreshes a mention created and saved again in one transaction' do
    Notification.transaction do
      notification = build_signal.tap(&:save!)
      notification.update!(score: 60)
    end

    expect(signal_jobs.size).to eq(1)
  end

  it 'refreshes a mention made unread and saved again in one transaction' do
    notification = build_signal(state: :read).tap(&:save!)
    clear_enqueued_jobs

    Notification.transaction do
      notification.mark_as_unread!
      notification.update!(score: 60)
    end

    expect(signal_jobs.size).to eq(1)
  end

  it 'does not refresh after a rollback' do
    Notification.transaction do
      build_signal.save!
      raise ActiveRecord::Rollback
    end

    expect(signal_jobs).to be_empty
  end

  it 'does not refresh when a read mention is created' do
    build_signal(state: :read).save!

    expect(signal_jobs).to be_empty
  end
end
