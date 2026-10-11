# frozen_string_literal: true

require 'rails_helper'

# Notification.bulk_transition! is the one way to change states in bulk:
# update_all skips after_commit, so the method itself refreshes the org switcher
# signal (Notifications::UnreadSignals) of every recipient it touched.
RSpec.describe Notification, '.bulk_transition!', :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:alice) { create(:user) }
  let(:bob) { create(:user) }

  before do
    ActiveJob::Base.queue_adapter = :test
    ActsAsTenant.current_tenant = organisation
  end

  # Setup only: factory saves are not the code under test for Prosopite.
  def notify(recipient, event_type: 'mention', state: :delivered, channel: 'in_app')
    Prosopite.pause
    create(:notification, recipient: recipient, organisation: organisation, project: nil,
                          event_type: event_type, channel: channel, state: state)
  ensure
    Prosopite.resume
  end

  def signal_user_ids
    enqueued_jobs.select { |job| job['job_class'] == 'Notifications::UnreadSignalsJob' }
                 .map { |job| job['arguments'].first['user_id'] }
  end

  it 'changes the rows of the relation and returns their number' do
    mine = notify(alice)
    other = notify(bob)

    count = Notification.where(id: mine.id).bulk_transition!(state: 'read', read_at: Time.current)

    expect(count).to eq(1)
    expect(mine.reload.state).to eq('read')
    expect(other.reload.state).to eq('delivered')
  end

  it 'refreshes the signal once per recipient it touched' do
    2.times { notify(alice) }
    notify(bob)
    clear_enqueued_jobs

    Notification.unread.bulk_transition!(state: 'read', read_at: Time.current)

    expect(signal_user_ids).to contain_exactly(alice.id, bob.id)
  end

  it 'refreshes recipients of every in-app event type' do
    notify(alice)
    notify(bob, event_type: 'ticket_commented')
    clear_enqueued_jobs

    Notification.unread.bulk_transition!(state: 'read', read_at: Time.current)

    expect(signal_user_ids).to contain_exactly(alice.id, bob.id)
  end

  it 'leaves out recipients whose touched rows carry no signal' do
    notify(alice)
    notify(bob, channel: 'email')
    clear_enqueued_jobs

    Notification.unread.bulk_transition!(state: 'read', read_at: Time.current)

    expect(signal_user_ids).to contain_exactly(alice.id)
  end

  it 'refreshes nothing when no row changed' do
    notify(alice, state: :read)
    clear_enqueued_jobs

    count = Notification.unread.bulk_transition!(state: 'read', read_at: Time.current)

    expect(count).to eq(0)
    expect(signal_user_ids).to be_empty
  end

  it 'works on an ordered relation' do
    notify(alice)
    clear_enqueued_jobs

    count = Notification.unread.order(:created_at).bulk_transition!(state: 'read', read_at: Time.current)

    expect(count).to eq(1)
    expect(signal_user_ids).to contain_exactly(alice.id)
  end

  it 'changes and refreshes only the rows a limited relation reads' do
    first = notify(alice)
    notify(bob)
    clear_enqueued_jobs

    count = Notification.unread.order(:created_at, :id).limit(1).bulk_transition!(state: 'read', read_at: Time.current)

    expect(count).to eq(1)
    expect(first.reload.state).to eq('read')
    expect(signal_user_ids).to contain_exactly(alice.id)
  end

  # A mention created between reading the rows and writing them must stay
  # untouched: otherwise the update reads it while no refresh names its recipient.
  it 'leaves a row alone that appears after the rows were read' do
    notify(alice)
    late = nil
    allow(Notification).to receive(:where).and_wrap_original do |original, *args, **kwargs|
      late ||= notify(bob) if kwargs.key?(:id)
      original.call(*args, **kwargs)
    end
    clear_enqueued_jobs

    count = Notification.unread.bulk_transition!(state: 'read', read_at: Time.current)

    expect(late).to be_present
    expect(count).to eq(1)
    expect(late.reload.state).to eq('delivered')
  end
end
