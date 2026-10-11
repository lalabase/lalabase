# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Post acknowledgement during outbox fanout' do
  self.use_transactional_tests = false

  before do
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.start
    Prosopite.pause
  end

  after { Prosopite.resume }

  it 'holds the post lock through the outer outbox commit, then consumes the notification' do
    organisation = create(:organisation)
    ActsAsTenant.current_tenant = organisation
    author = create(:user)
    reader = create(:user)
    project = create(:project, organisation: organisation)
    ticket = create(:ticket, organisation: organisation, project: project, creator: author)
    post_record = create(:post, organisation: organisation, ticket: ticket, user: author)
    activity = create(:activity, :post_added, organisation: organisation,
                                              trackable: ticket, actor: author, secondary: post_record)
    outbox = create(:outbox_event, organisation: organisation, activity: activity,
                                   event_type: 'ticket_commented', payload: { 'activity_id' => activity.id })
    service = Notifications::FanoutService.new(outbox)
    allow(Notifications::FanoutService).to receive(:new).and_return(service)
    allow(service).to receive(:find_recipients).and_return([reader])
    allow(service).to receive(:determine_channels_for_recipient).and_return([:in_app])
    allow(service).to receive(:should_notify_for_ticket?).and_return(true)

    ready = Queue.new
    release = Queue.new
    allow(service).to receive(:batch_broadcast) do
      ready << true
      release.pop
    end
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActsAsTenant.with_tenant(organisation) { outbox.process! }
      end
    end
    Timeout.timeout(10) { ready.pop }
    expect(reader.notifications).not_to exist # The worker has not committed yet.

    # The worker is held at the barrier. A bounded lock timeout proves the read
    # cannot pass it, without relying on sleeps or which thread runs faster.
    expect do
      PostRead.transaction do
        PostRead.connection.execute("SET LOCAL lock_timeout = '100ms'")
        Posts::MarkRead.call(post: post_record, user: reader)
      end
    end.to raise_error(ActiveRecord::LockWaitTimeout)
    expect(PostRead.where(post: post_record, user: reader)).not_to exist

    release << true
    expect(worker.join(10)).to be_present
    worker.value
    expect(outbox.reload).to be_processed

    Posts::MarkRead.call(post: post_record, user: reader)
    expect(reader.notifications.channel_in_app.sole).to be_state_read
  ensure
    release << true if release
    worker&.join(2)
    worker&.kill if worker&.alive?
  end
end
