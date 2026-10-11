# frozen_string_literal: true

require 'rails_helper'

# Diagnostic test: assignee does not receive a notification for comments
#
# Tests the complete flow:
# 1. User is assigned to the ticket → auto_subscribe_assignee creates a subscription
# 2. Someone posts a comment → Activity + OutboxEvent are created
# 3. FanoutService processes the event → assignee receives a notification
RSpec.describe 'Assignee receives comment notification (end-to-end)', type: :model do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:regular_role) { create(:role, organisation: organisation, title: 'member') }

  let(:creator) { create(:user) }
  let(:assignee) { create(:user) }
  let(:commenter) { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
    Current.user = creator
  end

  def create_outbox_event(activity)
    create(:outbox_event,
           organisation: organisation,
           activity: activity,
           event_type: Notifications::Constants.derive_event_type(activity.key, activity.action),
           payload: activity.parameters || {})
  end

  def run_fanout(activity)
    outbox_event = create_outbox_event(activity)
    # Pause Prosopite: FanoutService processes each recipient individually
    # (notification lookup, badge count) — per-recipient by design, not a classic N+1
    Prosopite.pause
    Notifications::FanoutService.new(outbox_event).call
  ensure
    Prosopite.resume
  end

  def notifications_for(user, ticket)
    Notification.where(recipient: user, notifiable: ticket, channel: 'in_app')
  end

  # =========================================================================
  # Step 1: Check whether auto_subscribe_assignee creates the subscription
  # =========================================================================

  describe 'auto_subscribe_assignee creates subscription' do
    context 'with admin role (full access)' do
      let(:ticket) { create(:ticket, project: project, creator: creator) }

      before do
        create(:membership, user: creator, organisation: organisation, role: admin_role, active: true)
        create(:membership, user: assignee, organisation: organisation, role: admin_role, active: true)
      end

      it 'creates a follow subscription when assignee is added' do
        expect do
          ticket.assignees << assignee
        end.to change { NotificationSubscription.where(user: assignee, subscribable: ticket, mode: :follow).count }.by(1)
      end
    end

    context 'with regular role and project permission (tickets_access)' do
      let(:ticket) { create(:ticket, project: project, creator: creator) }

      before do
        create(:membership, user: creator, organisation: organisation, role: admin_role, active: true)
        create(:membership, user: assignee, organisation: organisation, role: regular_role, active: true)
        create(:project_permission, user: assignee, project: project, tickets_access: 'read_write')
      end

      it 'creates a follow subscription when assignee is added' do
        expect do
          ticket.assignees << assignee
        end.to change { NotificationSubscription.where(user: assignee, subscribable: ticket, mode: :follow).count }.by(1)
      end
    end

    context 'with regular role but NO project permission' do
      let(:ticket) { create(:ticket, project: project, creator: creator) }

      before do
        create(:membership, user: creator, organisation: organisation, role: admin_role, active: true)
        create(:membership, user: assignee, organisation: organisation, role: regular_role, active: true)
        # No ProjectPermission → validate_user_has_access could fail
      end

      it 'creates a follow subscription via system_subscribe (bypasses access validation)' do
        expect do
          ticket.assignees << assignee
        end.to change { NotificationSubscription.where(user: assignee, subscribable: ticket, mode: :follow).count }.by(1)
      end
    end
  end

  # =========================================================================
  # Step 2: Complete end-to-end flow
  # =========================================================================

  describe 'full flow: assign → comment → notification' do
    context 'with admin role' do
      let(:ticket) { create(:ticket, project: project, creator: creator) }

      before do
        create(:membership, user: creator, organisation: organisation, role: admin_role, active: true)
        create(:membership, user: assignee, organisation: organisation, role: admin_role, active: true)
        create(:membership, user: commenter, organisation: organisation, role: admin_role, active: true)

        # Step 1: Assign the assignee
        ticket.assignees << assignee
      end

      it 'assignee receives notification when someone else posts a comment' do
        # Step 2: Create a comment as a different user
        Current.user = commenter
        activity = create(:activity, :post_added,
                          organisation: organisation, trackable: ticket, actor: commenter)

        # Step 3: Run FanoutService
        run_fanout(activity)

        # Check: assignee received a notification
        expect(notifications_for(assignee, ticket)).to exist
      end

      it 'assignee does NOT receive notification for own comment' do
        Current.user = assignee
        activity = create(:activity, :post_added,
                          organisation: organisation, trackable: ticket, actor: assignee)
        run_fanout(activity)

        expect(notifications_for(assignee, ticket)).not_to exist
      end
    end

    context 'with regular role and project permission' do
      let(:ticket) { create(:ticket, project: project, creator: creator) }

      before do
        create(:membership, user: creator, organisation: organisation, role: admin_role, active: true)
        create(:membership, user: assignee, organisation: organisation, role: regular_role, active: true)
        create(:membership, user: commenter, organisation: organisation, role: admin_role, active: true)
        create(:project_permission, user: assignee, project: project, tickets_access: 'read_write')

        ticket.assignees << assignee
      end

      it 'assignee with project permission receives notification for comment' do
        Current.user = commenter
        activity = create(:activity, :post_added,
                          organisation: organisation, trackable: ticket, actor: commenter)
        run_fanout(activity)

        expect(notifications_for(assignee, ticket)).to exist
      end
    end

    # This context used to pin the opposite and was labelled "Bug-Kandidat!" by its author.
    # It was one: the assignee here cannot open the ticket, so every notification they got
    # was a dead link carrying the ticket title. The first example proves the premise
    # rather than assuming it, so the day area_access? changes, this goes red HERE and
    # names the reason instead of leaving the second example mysteriously failing.
    context 'with regular role but NO project permission' do
      let(:ticket) { create(:ticket, project: project, creator: creator) }

      before do
        create(:membership, user: creator, organisation: organisation, role: admin_role, active: true)
        create(:membership, user: assignee, organisation: organisation, role: regular_role, active: true)
        create(:membership, user: commenter, organisation: organisation, role: admin_role, active: true)
        # No project_permission for the assignee!

        ticket.assignees << assignee
      end

      it 'cannot open the ticket at all' do
        expect(TicketPolicy.new(assignee, ticket).show?).to be(false)
      end

      it 'receives no notification, because a subscription is not a permission' do
        Current.user = commenter
        activity = create(:activity, :post_added,
                          organisation: organisation, trackable: ticket, actor: commenter)
        run_fanout(activity)

        expect(notifications_for(assignee, ticket)).not_to exist
      end
    end
  end

  # =========================================================================
  # Step 3: Check the subscription chain in detail
  # =========================================================================

  describe 'subscription chain diagnostics' do
    let(:ticket) { create(:ticket, project: project, creator: creator) }

    before do
      create(:membership, user: creator, organisation: organisation, role: admin_role, active: true)
      create(:membership, user: assignee, organisation: organisation, role: admin_role, active: true)
      create(:membership, user: commenter, organisation: organisation, role: admin_role, active: true)
    end

    it 'shows subscription state at each step' do
      # Before assignment: no subscription for the assignee
      expect(NotificationSubscription.where(user: assignee, subscribable: ticket)).not_to exist

      # Assignment
      ticket.assignees << assignee

      # After assignment: is the subscription present?
      subscription = NotificationSubscription.find_by(user: assignee, subscribable: ticket)
      expect(subscription).to be_present, 'Expected subscription to be created by auto_subscribe_assignee'
      expect(subscription.mode).to eq('follow')

      # Does FanoutService find the subscriber?
      Current.user = commenter
      activity = create(:activity, :post_added,
                        organisation: organisation, trackable: ticket, actor: commenter)
      outbox_event = create_outbox_event(activity)
      service = Notifications::FanoutService.new(outbox_event)

      recipients = service.send(:find_ticket_recipients, ticket)
      expect(recipients).to include(assignee), "Expected assignee to be in recipients, got: #{recipients.map(&:email).join(', ')}"

      # Is the notification created?
      run_fanout(activity)
      expect(notifications_for(assignee, ticket)).to exist
    end
  end
end
