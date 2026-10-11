# frozen_string_literal: true

# skip_email channel override (doc/onboarding_plan.md, Outside Voice #1/#8):
# ticket notifications are hard-wired to [:in_app, :email]. Seeded onboarding
# assignments must reach the inbox WITHOUT triggering assignment e-mails right
# after signup — the override has to cut the email channel BEFORE notification
# creation (an email Notification row could still be delivered later by
# retries/jobs, so suppressing delivery alone is not enough). The contract:
# with skip_email there is no email Notification AND no EmailDeliveryJob.
require 'rails_helper'

RSpec.describe Notifications::FanoutService, 'skip_email channel override' do
  include ActiveJob::TestHelper

  # The have_enqueued_job matcher needs the :test adapter; restore whatever the
  # suite normally runs with so this file cannot leak adapter state.
  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    ActiveJob::Base.queue_adapter = original
  end

  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:creator) { create(:user) }
  let(:actor) { create(:user) }
  let(:assignee) { create(:user) }
  let(:ticket) { create(:ticket, project: project, creator: creator) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    Current.user = actor

    create(:membership, user: creator, organisation: organisation, role: admin_role, active: true)
    create(:membership, user: actor, organisation: organisation, role: admin_role, active: true)
    create(:membership, user: assignee, organisation: organisation, role: admin_role, active: true)
  end

  def run_fanout(activity)
    outbox_event = create(:outbox_event,
                          organisation: organisation,
                          activity: activity,
                          event_type: Notifications::Constants.derive_event_type(activity.key, activity.action),
                          payload: activity.parameters || {})
    Prosopite.pause
    result = described_class.new(outbox_event).call
    Prosopite.resume
    result
  end

  def assignment_activity(extra_parameters = {})
    create(:activity, :assigned,
           organisation: organisation, trackable: ticket, actor: actor,
           secondary: assignee,
           parameters: { 'assignee_id' => assignee.id }.merge(extra_parameters))
  end

  context 'with skip_email in the activity parameters' do
    it 'creates the in_app notification but NO email notification and NO email job' do
      expect do
        run_fanout(assignment_activity('skip_email' => true))
      end.not_to have_enqueued_job(EmailDeliveryJob)

      expect(Notification.where(recipient: assignee, notifiable: ticket, channel: 'in_app')).to exist
      expect(Notification.where(recipient: assignee, notifiable: ticket, channel: 'email')).not_to exist
    end
  end

  context 'without skip_email (regression guard for the default)' do
    it 'creates in_app AND email notifications as before' do
      run_fanout(assignment_activity)

      expect(Notification.where(recipient: assignee, notifiable: ticket, channel: 'in_app')).to exist
      expect(Notification.where(recipient: assignee, notifiable: ticket, channel: 'email')).to exist
    end

    # Boundary of the truthiness check: an explicit false must behave like an
    # absent flag (both channels). Kills the mutation that turns the guard into
    # a mere key-presence check (`parameters.key?('skip_email')`).
    it 'treats an explicit skip_email: false like an absent flag' do
      run_fanout(assignment_activity('skip_email' => false))

      expect(Notification.where(recipient: assignee, notifiable: ticket, channel: 'email')).to exist
    end
  end
end
