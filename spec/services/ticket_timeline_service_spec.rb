# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TicketTimelineService do
  include ActiveSupport::Testing::TimeHelpers
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }
  let(:service) { described_class.new(ticket, user) }

  # The 'created' Activity is filtered since 05.09.2026 - the ticket's birth
  # rides along as the always-present CreationMarker instead, sorting by the
  # ticket's created_at.
  def creation_marker(items)
    items.find { |i| i.is_a?(described_class::CreationMarker) }
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
    Current.user = user
  end

  describe '#timeline_items' do
    context 'with mixed timeline items' do
      let(:base_time) { Time.current }
      let!(:created_activity) do
        travel_to(base_time - 4.hours) do
          ticket # This triggers creation activity
          ticket.activities.where(action: 'created').first
        end
      end
      let!(:post1) { create(:post, ticket: ticket, created_at: base_time - 3.hours) }
      let!(:time_session) { create(:time_session, ticket: ticket, occurred_on: base_time - 2.hours) }
      let!(:post2) { create(:post, ticket: ticket, created_at: base_time - 1.hour) }
      let!(:updated_activity) do
        travel_to(base_time - 30.minutes) do
          ticket.update!(title: 'Updated Title')
          ticket.activities.where(action: 'title_changed').first
        end
      end

      before do
        # Create TimeSessionPermission so user can see time sessions
        create(:time_session_permission,
               user: user,
               project: project,
               can_view_own: true,
               can_view_all: true)
      end

      it 'returns all items in chronological order' do
        items = service.timeline_items

        # Includes posts, time session, and various activities from callbacks;
        # the created activity is filtered, the marker stands in its place.
        expect(items).to include(post1, time_session, post2, updated_activity)
        expect(items).not_to include(created_activity)
        marker = creation_marker(items)
        expect(marker).to be_present

        # Check relative chronological order of known items
        indices = [marker, post1, time_session, post2, updated_activity].map { |item| items.index(item) }
        expect(indices).to eq(indices.sort)
      end
    end

    context 'with only activities' do
      before do
        ticket.update!(title: 'New Title')
        ticket.track_assignee_added(user)
      end

      it 'includes activities in the timeline (plus the creation marker)' do
        items = service.timeline_items

        activities = items.reject { |i| i.is_a?(described_class::CreationMarker) }
        expect(activities).to all(be_a(Activity))
        expect(activities.size).to be >= 2
        expect(creation_marker(items)).to be_present
      end
    end
  end

  # Click cascades collapse (designer round 05.09.2026): adjacent activities
  # on the same field by the same person, each within 30 minutes of the
  # previous one, become one ActivityRun. Anything else between two steps
  # breaks the run - the reader saw something happen in between.
  describe 'activity run collapsing' do
    let(:colleague) { create(:user, first_name: 'Anna', last_name: 'Berg') }
    let(:base_time) { Time.zone.local(2026, 4, 22, 10, 0) }

    def step(action, at, actor: user, secondary: colleague)
      activity = create(:activity, action: action, key: "ticket.#{action}",
                                   trackable: ticket, actor: actor, organisation: organisation,
                                   secondary: secondary, parameters: { 'display_name' => 'T' })
      activity.update_column(:created_at, at)
      activity
    end

    def runs(items)
      items.select { |i| i.is_a?(described_class::ActivityRun) }
    end

    it 'wraps adjacent same-field steps by the same person into one run' do
      first = step('subscriber_added', base_time)
      second = step('subscriber_removed', base_time + 2.minutes)
      third = step('subscriber_added', base_time + 4.minutes)

      items = service.timeline_items
      run = runs(items).sole

      expect(run.activities).to eq([first, second, third])
      expect(items).not_to include(first, second, third)
      # The run sorts and dates by its NEWEST step; the span starts at the oldest.
      expect(run.created_at).to eq(third.created_at)
      expect(run.first_at).to eq(first.created_at)
      expect(run.field).to eq(:subscribers)
    end

    it 'keeps a single step a plain activity' do
      only = step('subscriber_added', base_time)

      items = service.timeline_items
      expect(runs(items)).to be_empty
      expect(items).to include(only)
    end

    it 'splits at a gap of more than 30 minutes' do
      step('subscriber_added', base_time)
      step('subscriber_removed', base_time + 31.minutes)

      expect(runs(service.timeline_items)).to be_empty
    end

    it 'splits when the person switches' do
      step('subscriber_added', base_time)
      step('subscriber_removed', base_time + 1.minute, actor: colleague)

      expect(runs(service.timeline_items)).to be_empty
    end

    it 'splits when another item stands between the steps' do
      step('subscriber_added', base_time)
      create(:post, ticket: ticket, created_at: base_time + 1.minute)
      step('subscriber_removed', base_time + 2.minutes)

      expect(runs(service.timeline_items)).to be_empty
    end

    it 'does not mix fields' do
      step('status_changed', base_time, secondary: nil)
      step('priority_changed', base_time + 1.minute, secondary: nil)

      expect(runs(service.timeline_items)).to be_empty
    end

    it 'orders the steps inside the run like the timeline itself when reversed' do
      first = step('subscriber_added', base_time)
      second = step('subscriber_removed', base_time + 2.minutes)
      user.update!(preferences: { 'post_direction' => 'reverse' })

      run = runs(service.timeline_items).sole
      expect(run.activities).to eq([second, first])
      # Order-independent accessors keep the span honest either way.
      expect(run.created_at).to eq(second.created_at)
      expect(run.first_at).to eq(first.created_at)
    end
  end

  describe '#timeline_count' do
    let!(:post) { create(:post, ticket: ticket) }
    let!(:time_session) { create(:time_session, ticket: ticket) }

    before do
      ticket.update!(title: 'Updated')
    end

    it 'returns correct count without loading items' do
      expect(service.timeline_count).to be >= 3 # 1 post + 1 time session + activities
    end
  end

  describe 'permission-based filtering' do
    let(:other_user) { create(:user) }
    let!(:own_time_session) { create(:time_session, ticket: ticket, creator: user, occurred_on: 3.hours.ago, duration: 60) }
    let!(:other_time_session) { create(:time_session, ticket: ticket, creator: other_user, occurred_on: 2.hours.ago, duration: 90) }
    let!(:post) { create(:post, ticket: ticket, created_at: 1.hour.ago) }

    before do
      # Set up memberships (only if not already exists)
      Membership.find_or_create_by!(user: other_user, organisation: organisation) do |m|
        m.active = true
      end
    end

    context 'when user has can_view_own permission only' do
      before do
        # Create TimeSessionPermission with only view_own
        create(:time_session_permission,
               user: user,
               project: project,
               can_view_own: true,
               can_view_all: false,
               can_create_own: true,
               can_edit_own: false,
               can_edit_all: false,
               can_delete_own: false,
               can_delete_all: false)
      end

      it 'includes only own time sessions in timeline' do
        service = described_class.new(ticket, user)
        items = service.timeline_items

        # Should include post, activities, and only own time session
        time_sessions_in_timeline = items.select { |item| item.is_a?(TimeSession) }

        expect(time_sessions_in_timeline.size).to eq(1)
        expect(time_sessions_in_timeline.first).to eq(own_time_session)
        expect(time_sessions_in_timeline).not_to include(other_time_session)
      end
    end

    context 'when user has can_view_all permission' do
      before do
        # Create TimeSessionPermission with view_all
        create(:time_session_permission,
               user: user,
               project: project,
               can_view_own: true,
               can_view_all: true,
               can_create_own: true,
               can_edit_own: false,
               can_edit_all: false,
               can_delete_own: false,
               can_delete_all: false)
      end

      it 'includes all time sessions in timeline' do
        service = described_class.new(ticket, user)
        items = service.timeline_items

        time_sessions_in_timeline = items.select { |item| item.is_a?(TimeSession) }

        expect(time_sessions_in_timeline.size).to eq(2)
        expect(time_sessions_in_timeline).to include(own_time_session, other_time_session)
      end
    end

    context 'when user has no time session permissions' do
      before do
        # No TimeSessionPermission created for this user
      end

      it 'excludes all time sessions from timeline' do
        service = described_class.new(ticket, user)
        items = service.timeline_items

        time_sessions_in_timeline = items.select { |item| item.is_a?(TimeSession) }

        expect(time_sessions_in_timeline).to be_empty
      end

      it 'still includes posts and activities' do
        service = described_class.new(ticket, user)
        items = service.timeline_items

        posts_in_timeline = items.select { |item| item.is_a?(Post) }
        activities_in_timeline = items.select { |item| item.is_a?(Activity) }

        expect(posts_in_timeline).not_to be_empty
        expect(activities_in_timeline).not_to be_empty
      end
    end

    context 'when no user is provided (backward compatibility)' do
      it 'includes all time sessions' do
        service = described_class.new(ticket, nil)
        items = service.timeline_items

        time_sessions_in_timeline = items.select { |item| item.is_a?(TimeSession) }

        expect(time_sessions_in_timeline.size).to eq(2)
        expect(time_sessions_in_timeline).to include(own_time_session, other_time_session)
      end
    end

    context 'with mixed permissions and multiple users' do
      let(:third_user) { create(:user) }
      let!(:third_time_session) { create(:time_session, ticket: ticket, creator: third_user, occurred_on: 4.hours.ago, duration: 120) }

      before do
        Membership.find_or_create_by!(user: third_user, organisation: organisation) do |m|
          m.active = true
        end

        # User can see only own
        create(:time_session_permission,
               user: user,
               project: project,
               can_view_own: true,
               can_view_all: false)

        # Other user can see all
        create(:time_session_permission,
               user: other_user,
               project: project,
               can_view_own: true,
               can_view_all: true)

        # Third user has no permissions
      end

      it 'correctly filters based on each users permissions' do
        # First user sees only own
        service1 = described_class.new(ticket, user)
        items1 = service1.timeline_items
        time_sessions1 = items1.select { |item| item.is_a?(TimeSession) }

        expect(time_sessions1.size).to eq(1)
        expect(time_sessions1.first).to eq(own_time_session)

        # Other user sees all
        service2 = described_class.new(ticket, other_user)
        items2 = service2.timeline_items
        time_sessions2 = items2.select { |item| item.is_a?(TimeSession) }

        expect(time_sessions2.size).to eq(3)
        expect(time_sessions2).to include(own_time_session, other_time_session, third_time_session)

        # Third user sees none (no permissions)
        service3 = described_class.new(ticket, third_user)
        items3 = service3.timeline_items
        time_sessions3 = items3.select { |item| item.is_a?(TimeSession) }

        expect(time_sessions3).to be_empty
      end
    end

    context 'when user is an admin with no local permissions' do
      let(:admin_user) { create(:user) }

      before do
        # Create admin membership with account_admin role
        admin_role = create(:role, organisation: organisation, title: 'account_admin')
        create(:membership, user: admin_user, organisation: organisation, role: admin_role, active: true)

        # No TimeSessionPermission for admin - they rely on global rights
      end

      it 'allows admin to see all time sessions despite having no local permissions' do
        service = described_class.new(ticket, admin_user)
        items = service.timeline_items

        time_sessions_in_timeline = items.select { |item| item.is_a?(TimeSession) }

        expect(time_sessions_in_timeline.size).to eq(2)
        expect(time_sessions_in_timeline).to include(own_time_session, other_time_session)
      end
    end
  end

  describe 'performance optimizations' do
    it 'uses preloaded associations when available' do
      # Preload associations
      ticket_with_associations = Ticket.includes(
        posts: %i[user rich_text_content],
        time_sessions: :creator,
        activities: %i[actor secondary]
      ).find(ticket.id)

      service = described_class.new(ticket_with_associations, user)

      # Should successfully load timeline items
      expect(service.timeline_items).to be_an(Array)
    end

    it 'loads associations efficiently when not preloaded' do
      # Pause N+1 detection during factory setup (callbacks trigger unrelated queries)
      Prosopite.pause
      create_list(:post, 3, ticket: ticket)
      create_list(:time_session, 2, ticket: ticket)
      Prosopite.resume

      # Should successfully load timeline items
      expect(service.timeline_items).to be_an(Array)
      expect(service.timeline_items.size).to be_positive
    end
  end

  describe 'timeline ordering' do
    let(:base_time) { Time.current }
    let!(:created_activity) do
      travel_to(base_time - 4.hours) do
        ticket # This triggers creation activity
        ticket.activities.where(action: 'created').first
      end
    end
    let!(:post1) { create(:post, ticket: ticket, created_at: base_time - 3.hours) }
    let!(:time_session) { create(:time_session, ticket: ticket, occurred_on: base_time - 2.hours) }
    let!(:post2) { create(:post, ticket: ticket, created_at: base_time - 1.hour) }
    let!(:updated_activity) do
      travel_to(base_time - 30.minutes) do
        ticket.update!(title: 'Updated Title')
        ticket.activities.where(action: 'title_changed').first
      end
    end

    before do
      create(:time_session_permission,
             user: user,
             project: project,
             can_view_own: true,
             can_view_all: true)
    end

    context 'when user prefers chronological order (default)' do
      before do
        user.update!(preferences: { 'post_direction' => 'chronological' })
      end

      it 'returns items in chronological order (oldest first)' do
        items = service.timeline_items

        expect(items).to include(post1, time_session, post2, updated_activity)
        indices = [creation_marker(items), post1, time_session, post2, updated_activity].map { |item| items.index(item) }
        expect(indices).to eq(indices.sort)
      end
    end

    context 'when user prefers reverse order' do
      before do
        user.update!(preferences: { 'post_direction' => 'reverse' })
      end

      it 'returns items in reverse chronological order (newest first)' do
        items = service.timeline_items

        expect(items).to include(post1, time_session, post2, updated_activity)
        indices = [updated_activity, post2, time_session, post1, creation_marker(items)].map { |item| items.index(item) }
        expect(indices).to eq(indices.sort)
      end
    end

    context 'when no user is provided' do
      let(:service_no_user) { described_class.new(ticket, nil) }

      it 'defaults to chronological order' do
        items = service_no_user.timeline_items

        expect(items).to include(post1, time_session, post2, updated_activity)
        indices = [creation_marker(items), post1, time_session, post2, updated_activity].map { |item| items.index(item) }
        expect(indices).to eq(indices.sort)
      end
    end

    context 'when user has no preference set' do
      before do
        user.update!(preferences: {})
      end

      it 'defaults to chronological order' do
        items = service.timeline_items

        expect(items).to include(post1, time_session, post2, updated_activity)
        indices = [creation_marker(items), post1, time_session, post2, updated_activity].map { |item| items.index(item) }
        expect(indices).to eq(indices.sort)
      end
    end
  end

  describe 'activity filtering' do
    let(:base_time) { Time.current }
    let!(:post) { create(:post, ticket: ticket, created_at: base_time - 2.hours) }

    before do
      # Create a post_added activity (would normally be created by SavePost service)
      create(:activity,
             trackable: ticket,
             action: 'post_added',
             key: 'ticket.post_added',
             actor: user,
             organisation: organisation,
             secondary: post,
             created_at: base_time - 2.hours)

      # Create a non-post activity that should still appear
      create(:activity,
             trackable: ticket,
             action: 'status_changed',
             key: 'ticket.status_changed',
             actor: user,
             organisation: organisation,
             created_at: base_time - 1.hour)
    end

    it 'filters out redundant post_added activities but keeps other activities' do
      items = service.timeline_items

      posts_in_timeline = items.select { |item| item.is_a?(Post) }
      activities_in_timeline = items.select { |item| item.is_a?(Activity) }

      # Post should be in timeline
      expect(posts_in_timeline.size).to eq(1)
      expect(posts_in_timeline.first).to eq(post)

      # post_added activity should be filtered out
      post_added_activities = activities_in_timeline.select { |activity| activity.action == 'post_added' }
      expect(post_added_activities).to be_empty

      # Other activities should still appear
      other_activities = activities_in_timeline.select { |activity| activity.action != 'post_added' }
      expect(other_activities.size).to be >= 1

      # Our specific status_changed activity should be present
      status_changed_activities = other_activities.select { |activity| activity.action == 'status_changed' }
      expect(status_changed_activities.size).to eq(1)
    end

    it 'does not affect the database - activities are still stored' do
      # Verify activities still exist in database
      expect(ticket.activities.where(action: 'post_added')).to exist
      expect(ticket.activities.where(action: 'status_changed')).to exist

      # But timeline service filters them out
      timeline_activities = service.timeline_items.select { |item| item.is_a?(Activity) }
      expect(timeline_activities.any? { |a| a.action == 'post_added' }).to be false
    end
  end
end
