# frozen_string_literal: true

require 'rails_helper'

# Every change of an in-app notification a list shows (its state, a new event
# of its group, its creation, its removal) refreshes the signals of
# Notifications::UnreadSignals: the switcher dot and the signal of the inbox
# above the organisations. The callback covers every
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

  # The same job sends the signal of the inbox above the organisations
  # (Notifications::Streams.all_inboxes): that page lists read and archived rows
  # too, so every change a row of it shows counts, not only unread ones.
  describe 'for the inbox above the organisations' do
    it 'refreshes when a read mention is created' do
      expect { build_signal(state: :read).save! }
        .to have_enqueued_job(Notifications::UnreadSignalsJob).with(user_id: user.id)
    end

    it 'refreshes when a read row is archived' do
      notification = build_signal(state: :read).tap(&:save!)
      clear_enqueued_jobs

      notification.archive!

      expect(signal_jobs.size).to eq(1)
    end

    it 'refreshes when an archived row comes back read' do
      notification = build_signal(state: :archived).tap(&:save!)
      clear_enqueued_jobs

      notification.update!(state: :read, archived_at: nil)

      expect(signal_jobs.size).to eq(1)
    end

    # A new event joins a group that is still unread: no state change, but the
    # row moves up and names one more event.
    it 'refreshes when a new event joins an unread group' do
      notification = build_signal.tap(&:save!)
      clear_enqueued_jobs

      notification.update!(last_event_at: 1.minute.from_now, group_count: 2)

      expect(signal_jobs.size).to eq(1)
    end

    it 'refreshes when a read row is destroyed' do
      notification = build_signal(state: :read).tap(&:save!)
      clear_enqueued_jobs

      expect { notification.destroy! }.to have_enqueued_job(Notifications::UnreadSignalsJob)
    end

    it 'does not refresh for a delivery step that leaves the row unread' do
      notification = build_signal(state: :queued).tap(&:save!)
      clear_enqueued_jobs

      notification.update!(state: :delivered)

      expect(signal_jobs).to be_empty
    end

    it 'does not refresh for a read email row either' do
      build_signal(channel: 'email', state: :read).save!

      expect(signal_jobs).to be_empty
    end
  end
end
