# frozen_string_literal: true

require 'rails_helper'

# A notification subscription is not a standing permission.
#
# Whoever loses access to a project must stop receiving its notifications. The rows stay
# where they are, so that returning to the project restores the old state without anyone
# having to put it back: the gate is DERIVED from current access, never stored.
#
# The organisation case rides on the same gate for free, because
# AccessCheck::ProjectAccessService.accessible_project_ids refuses a non-member before it
# looks at any project. If that ever stops being true, the org example here goes red first.
RSpec.describe Notifications::FanoutService, 'project access gate' do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:member_role) { create(:role, organisation: organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }

  let(:member) { create(:user) }
  let(:actor) { create(:user) }
  let(:ticket) { create(:ticket, project: project, creator: actor) }

  # Lazy on purpose: a let! would run before the before-block below and hit NoTenantSet.
  let(:membership) do
    create(:membership, user: member, organisation: organisation, role: member_role, active: true)
  end

  let(:permission) do
    create(:project_permission, user: member, project: project, tickets_access: 'read_write')
  end

  before do
    ActsAsTenant.current_tenant = organisation
    Current.user = actor

    create(:membership, user: actor, organisation: organisation, role: admin_role, active: true)

    membership
    permission
    ticket
    NotificationSubscription.create!(user: member, subscribable: ticket, mode: 'follow')
  end

  def comment_on_ticket
    activity = create(:activity, :post_added,
                      organisation: organisation, trackable: ticket, actor: actor)
    outbox_event = create(:outbox_event,
                          organisation: organisation,
                          activity: activity,
                          event_type: Notifications::Constants.derive_event_type(activity.key, activity.action),
                          payload: activity.parameters || {})
    Prosopite.pause
    described_class.new(outbox_event).call
  ensure
    Prosopite.resume
  end

  def notifications_for(user)
    Notification.where(recipient: user, notifiable: ticket)
  end

  describe 'while the member still has access' do
    it 'notifies them' do
      comment_on_ticket

      expect(notifications_for(member)).to exist
    end
  end

  describe 'after the project access is taken away' do
    before { permission.update!(tickets_access: 'no_access') }

    it 'creates no notification' do
      comment_on_ticket

      expect(notifications_for(member)).not_to exist
    end

    it 'leaves the subscription in place, so the return needs no repair' do
      expect(NotificationSubscription.find_by(user: member, subscribable: ticket)).to be_present
    end
  end

  describe 'after the organisation membership is gone' do
    before { membership.destroy! }

    it 'creates no notification' do
      comment_on_ticket

      expect(notifications_for(member)).not_to exist
    end
  end

  describe 'after a deactivated membership' do
    before { membership.update!(active: false) }

    it 'creates no notification' do
      comment_on_ticket

      expect(notifications_for(member)).not_to exist
    end
  end

  # The generic (non-ticket) path merges subscribers in a second branch of its own, so it
  # needs its own example. This is the branch the old RevokeProjectMember worked around by
  # deleting the subscription row.
  describe 'project news for a subscriber who lost the project' do
    def announce_on_project
      activity = create(:activity,
                        organisation: organisation, trackable: project, actor: actor,
                        action: 'updated', key: 'project.updated',
                        parameters: { 'project_name' => 'Kickoff am Montag' })
      outbox_event = create(:outbox_event,
                            organisation: organisation,
                            activity: activity,
                            event_type: Notifications::Constants.derive_event_type(activity.key, activity.action),
                            payload: activity.parameters || {})
      Prosopite.pause
      described_class.new(outbox_event).call
    ensure
      Prosopite.resume
    end

    before { NotificationSubscription.system_subscribe(user: member, item: project) }

    it 'notifies them while they still have access' do
      announce_on_project

      expect(Notification.where(recipient: member, notifiable: project)).to exist
    end

    it 'creates no notification once the access is gone' do
      permission.update!(tickets_access: 'no_access')

      announce_on_project

      expect(Notification.where(recipient: member, notifiable: project)).not_to exist
    end
  end

  describe 'when access comes back' do
    it 'notifies again without anything being restored' do
      permission.update!(tickets_access: 'no_access')
      comment_on_ticket
      expect(notifications_for(member)).not_to exist

      permission.update!(tickets_access: 'read_write')
      member.instance_variable_set(:@active_member_cache, nil)
      comment_on_ticket

      expect(notifications_for(member)).to exist
    end
  end
end
