# frozen_string_literal: true

require 'rails_helper'

# The sidebar "Inbox" item is one <li><a> with a bell icon; only the label
# inside it lives in the permanent Turbo frame `nav_notifications_count`.
# Four places write that frame with a replace action: three turbo_stream
# templates of the notifications controller and the Turbo broadcast fired for
# every new or updated notification. A replace swaps the frame for the ROOT of
# the rendered template. If that root is the whole nav item instead of the
# frame, every update nests one more item (one more bell, one more link) inside
# the existing one. Seen on 08.09.2026: two bells after the first update.
#
# The four writers share one invariant, so they share one spec: whatever they
# send, applied to the real sidebar item the way Turbo applies it, must leave
# exactly one bell, one link, one frame, and the fresh label.
RSpec.describe 'Inbox sidebar count stream keeps one bell', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end
  let!(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end
  let!(:ticket) do
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) }
  end
  let!(:notification) do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: user, organisation: organisation, project: project,
             notifiable: ticket, channel: 'in_app', state: :delivered)
    end
  end

  let(:turbo_headers) { { 'Accept' => 'text/vnd.turbo-stream.html' } }

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause # Pre-existing N+1 in the inbox render path (see inbox_pane_flow_spec).
  end
  after { Prosopite.resume }

  # The sidebar item exactly as the layout renders it: GET the inbox and cut
  # out the <li> that carries the frame.
  def sidebar_item
    get organisation_notifications_path(organisation, state_filters: ['unread'])
    expect(response).to have_http_status(:ok)
    frame = Nokogiri::HTML5(response.body).at_css('turbo-frame#nav_notifications_count')
    expect(frame).not_to be_nil, 'the sidebar renders no nav_notifications_count frame'
    item = frame.ancestors('li').first
    expect(item.css('i.bi-bell').size).to eq(1)
    Nokogiri::HTML5.fragment(item.to_html)
  end

  # What Turbo does with a stream element for the two actions the writers may
  # use: replace swaps the target for the template's root nodes, update swaps
  # only the target's children. Parses the stream afresh on every call, so the
  # same response can be applied twice like two broadcasts in a row.
  def apply_stream(item, stream_html)
    streams = Nokogiri::HTML5.fragment(stream_html).css('turbo-stream[target="nav_notifications_count"]')
    expect(streams.size).to eq(1), "expected exactly one stream for the nav count, got #{streams.size}"
    stream = streams.first
    template = stream.at_css('template')
    target = item.at_css('#nav_notifications_count')
    expect(target).not_to be_nil, 'the frame is gone from the sidebar item'
    case stream['action']
    when 'replace' then target.replace(template.children)
    when 'update'  then target.children = template.children
    else raise "unexpected stream action #{stream['action'].inspect}"
    end
    item
  end

  shared_examples 'one bell after every update' do
    it 'leaves one bell, one link and one frame, with the fresh label, after two updates' do
      item = sidebar_item
      stream = stream_body
      apply_stream(item, stream)
      apply_stream(item, stream)

      # The count-data frame travels with the sidebar frame: one partial owns
      # both streams, so every writer sends both or neither.
      expect(Nokogiri::HTML5.fragment(stream).css('turbo-stream[target="notification_count_data"]').size).to eq(1)

      aggregate_failures do
        expect(item.css('i.bi-bell').size).to eq(1)
        expect(item.css('a').size).to eq(1)
        expect(item.css('turbo-frame#nav_notifications_count').size).to eq(1)
        expect(item.at_css('[data-notification-count-listener-target="label"]').text.strip)
          .to eq(I18n.t('navigation.notifications_label', count: 0))
      end
    end
  end

  describe 'PATCH mark_read (renders update.turbo_stream.erb)' do
    let(:stream_body) do
      patch mark_read_organisation_notification_path(organisation, notification), headers: turbo_headers
      expect(response).to have_http_status(:ok)
      response.body
    end

    include_examples 'one bell after every update'
  end

  describe 'PATCH mark_all_read' do
    let(:stream_body) do
      patch mark_all_read_organisation_notifications_path(organisation), headers: turbo_headers
      expect(response).to have_http_status(:ok)
      response.body
    end

    include_examples 'one bell after every update'
  end

  describe 'PATCH archive_all with ids[]' do
    let(:stream_body) do
      patch archive_all_organisation_notifications_path(organisation),
            params: { ids: [notification.id] }, headers: turbo_headers
      expect(response).to have_http_status(:ok)
      response.body
    end

    include_examples 'one bell after every update'
  end

  describe 'Turbo broadcast after a notification update (BroadcastService)' do
    # Solid Queue is the queue adapter in test as well; only the test adapter
    # lets perform_enqueued_jobs run the broadcast job, so what reaches the
    # stub below is the job's own rendering, not a hand-made stand-in.
    around do |example|
      adapter_was = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      example.run
    ensure
      ActiveJob::Base.queue_adapter = adapter_was
    end

    let(:stream_body) do
      sent = []
      allow(ActionCable.server).to receive(:broadcast) { |_stream, content| sent << content.to_s }
      # A request resets the tenant on this thread; the service counts
      # tenant-scoped notifications, as it does inside the fanout job.
      ActsAsTenant.with_tenant(organisation) do
        notification.mark_as_read!
        Notifications::BroadcastService.new(notification).broadcast_update
      end
      # Run the job afterwards, not inline inside the service call: a job runs
      # in the Rails executor, which resets every CurrentAttributes and with
      # them the tenant, so an inline run strips the tenant from the service
      # call still in progress. test_tenant lives on the thread and survives
      # that reset. Only the unread count job matters here (its locals carry
      # unread_count; the card and project badge jobs do not).
      begin
        ActsAsTenant.test_tenant = organisation
        perform_enqueued_jobs(only: ->(job) { job[:args].to_s.include?('unread_count') })
      ensure
        ActsAsTenant.test_tenant = nil
      end
      nav_streams = sent.grep(/target="nav_notifications_count"/)
      expect(nav_streams.size).to eq(1)
      nav_streams.first
    end

    include_examples 'one bell after every update'
  end
end
