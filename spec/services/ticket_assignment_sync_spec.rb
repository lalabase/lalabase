# frozen_string_literal: true

require 'rails_helper'

# Unit spec for the TicketAssignmentSync collaborator extracted from
# Actors::SaveTicket. Pins: the add/remove delta, the project-access filtering
# (assignable_user_ids — param tampering must not assign project-foreign members),
# the assignee notification subscriptions, and the assigned/unassigned activity
# tracking (attributed via Current.user, as set by the actor).
RSpec.describe TicketAssignmentSync do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:other_project) { create(:project, organisation: organisation) }
  let(:role) { create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true) }

  def member_with_access(to: project)
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    create(:project_permission, user: user, project: to, tickets_access: 'read_write')
    user
  end

  let(:creator) { member_with_access }
  let(:ticket) { create(:ticket, project: project, organisation: organisation, title: 'Assign', creator: creator) }

  before do
    ActsAsTenant.current_tenant = organisation
    Current.user = creator # activity attribution, normally set by BaseActor#with_actor_context
  end

  after do
    ActsAsTenant.current_tenant = nil
    Current.user = nil
  end

  it 'assigns a user with project access and follows them via subscription' do
    member = member_with_access

    described_class.call(ticket: ticket, assignee_ids: [member.id], is_new_ticket: true)

    expect(ticket.reload.assignees).to include(member)
    sub = NotificationSubscription.find_by(user_id: member.id, subscribable: ticket)
    expect(sub&.mode).to eq('follow')
  end

  it 'drops a project-foreign org member (param tampering via assignable_user_ids)' do
    foreigner = member_with_access(to: other_project)

    described_class.call(ticket: ticket, assignee_ids: [foreigner.id], is_new_ticket: true)

    expect(ticket.reload.assignees).not_to include(foreigner)
  end

  it 'removes assignees no longer present (empty set clears all)' do
    member = member_with_access
    described_class.call(ticket: ticket, assignee_ids: [member.id], is_new_ticket: true)

    described_class.call(ticket: ticket, assignee_ids: [], is_new_ticket: false)

    expect(ticket.reload.assignees).to be_empty
  end

  it 'tracks an assigned activity for an added assignee' do
    member = member_with_access

    expect { described_class.call(ticket: ticket, assignee_ids: [member.id], is_new_ticket: true) }
      .to change { Activity.where(trackable: ticket, action: 'assigned').count }.by(1)
  end

  it 'computes the delta from existing assignments when is_new_ticket is false' do
    keep = member_with_access
    drop = member_with_access
    described_class.call(ticket: ticket, assignee_ids: [keep.id, drop.id], is_new_ticket: true)

    # Only `drop` should be removed; `keep` stays — no churn on the unchanged one.
    described_class.call(ticket: ticket, assignee_ids: [keep.id], is_new_ticket: false)

    expect(ticket.reload.assignees).to contain_exactly(keep)
  end

  describe 'extra_activity_parameters (onboarding seed seam)' do
    # The seed threads skip_email through THIS path so there is exactly one
    # activity-creation seam. Both directions must carry the extras — an
    # asymmetric merge (only added, not removed) would silently mail on
    # future system-driven unassignments.
    it 'merges the extras into the assigned activity parameters' do
      member = member_with_access

      described_class.call(ticket: ticket, assignee_ids: [member.id], is_new_ticket: true,
                           extra_activity_parameters: { 'skip_email' => true })

      activity = Activity.where(trackable: ticket, action: 'assigned').last
      expect(activity.parameters['skip_email']).to be(true)
      # The standard GDPR-lean parameters must survive the merge.
      expect(activity.parameters).to have_key('display_name')
    end

    it 'merges the extras into the unassigned activity parameters too' do
      member = member_with_access
      described_class.call(ticket: ticket, assignee_ids: [member.id], is_new_ticket: true)

      described_class.call(ticket: ticket, assignee_ids: [], is_new_ticket: false,
                           extra_activity_parameters: { 'skip_email' => true })

      activity = Activity.where(trackable: ticket, action: 'unassigned').last
      expect(activity.parameters['skip_email']).to be(true)
    end
  end
end
