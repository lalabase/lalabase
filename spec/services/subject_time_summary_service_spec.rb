# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SubjectTimeSummaryService do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project) }
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:service) { described_class.new(subject: ticket, user: user) }

  before do
    ActsAsTenant.current_tenant = organisation
    # Create memberships for both users
    create(:membership, user: user, organisation: organisation)
    create(:membership, user: other_user, organisation: organisation)
    # Clean up any auto-created permissions from migration
    TimeSessionPermission.where(user: [user, other_user]).destroy_all
  end

  describe '#call' do
    # T20 regression guard: the chip, the ticket column and the list filter must
    # classify one booking the same way. Until #652 the chip read the billed flag
    # of the GROUP while everything else read the flag of the SESSION, and the
    # two come apart in a reachable state: TimeSessionGroup nullifies its
    # sessions on destroy and TimeSessionGroupsController#destroy has no guard
    # against a billed one, so deleting an invoiced billing leaves bookings with
    # billed: true and no group.
    it 'calls an invoiced booking without a group invoiced, like the list does' do
      create(:time_session_permission, user: user, project: project, can_view_all: true)
      group = create(:time_session_group, organisation: organisation)
      session = create(:time_session, project: project, organisation: organisation,
                                      creator: user, ticket: ticket, duration: 60,
                                      time_session_group: group, billed: true)
      group.destroy!
      session.reload

      expect(session.time_session_group_id).to be_nil
      expect(session.billed?).to be(true)
      expect(described_class.call(subject: ticket, user: user)[:billing_status]).to eq(:billed)
    end

    context 'when user is account admin' do
      before do
        # Create admin role and assign it to the user
        admin_role = create(:role, organisation: organisation, title: 'account_admin')
        membership = user.memberships.find_by(organisation: organisation)
        membership.update!(role: admin_role)
      end

      it 'returns summary with all time sessions' do
        create(:time_session, ticket: ticket, creator: user, duration: 60, organisation: organisation, project: project)
        create(:time_session, ticket: ticket, creator: other_user, duration: 120, organisation: organisation, project: project)

        result = service.call

        expect(result).to include(
          hours: 3.0,
          scope: :all,
          can_view: true
        )
      end
    end

    context 'when user has can_view_all permission' do
      let!(:time_permission) do
        create(:time_session_permission,
               user: user,
               project: project,
               can_view_all: true)
      end

      it 'returns summary with all time sessions' do
        create(:time_session, ticket: ticket, creator: user, duration: 60, organisation: organisation, project: project)
        create(:time_session, ticket: ticket, creator: other_user, duration: 120, organisation: organisation, project: project)

        result = service.call

        expect(result).to include(
          hours: 3.0,
          scope: :all,
          can_view: true
        )
      end
    end

    context 'when user has can_view_own permission only' do
      let!(:time_permission) do
        create(:time_session_permission,
               user: user,
               project: project,
               can_view_own: true,
               can_view_all: false)
      end

      it 'returns summary with only own time sessions' do
        create(:time_session, ticket: ticket, creator: user, duration: 60, organisation: organisation, project: project)
        create(:time_session, ticket: ticket, creator: other_user, duration: 120, organisation: organisation, project: project)

        result = service.call

        expect(result).to include(
          hours: 1.0,
          scope: :own,
          can_view: true
        )
      end
    end

    context 'when user has no view permissions' do
      let!(:time_permission) do
        create(:time_session_permission,
               user: user,
               project: project,
               can_view_own: false,
               can_view_all: false)
      end

      it 'returns nil' do
        create(:time_session, ticket: ticket, creator: user, duration: 60, organisation: organisation, project: project)

        result = service.call

        expect(result).to be_nil
      end
    end

    context 'when user has no time permission record' do
      it 'returns empty result showing no access' do
        # Debug: Check if user is accidentally an admin
        expect(user.account_admin_in?(organisation)).to eq(false)

        # Ensure no TimeSessionPermission exists
        expect(TimeSessionPermission.where(user: user, project: project).count).to eq(0)

        create(:time_session, ticket: ticket, creator: user, duration: 60, organisation: organisation, project: project)

        result = service.call

        # User can't view any sessions without permission, but still gets a result structure.
        # scope is :none (S2: the tier comes from TimeSessions::ViewingScope, which only
        # counts a PERSISTED permission row), not :own from the unsaved default row.
        expect(result).to include(
          total_minutes: 0,
          hours: 0.0,
          billing_status: :no_sessions,
          can_view: true,
          scope: :none
        )
      end
    end

    context 'with fractional hours' do
      let!(:time_permission) do
        create(:time_session_permission,
               user: user,
               project: project,
               can_view_own: true)
      end

      it 'rounds to 2 decimal places' do
        create(:time_session, ticket: ticket, creator: user, duration: 91, organisation: organisation, project: project)

        result = service.call

        expect(result[:hours]).to eq(1.52)
      end
    end

    context 'with no time sessions' do
      let!(:time_permission) do
        create(:time_session_permission,
               user: user,
               project: project,
               can_view_all: true)
      end

      it 'returns 0 hours' do
        result = service.call

        expect(result).to include(
          hours: 0.0,
          scope: :all,
          can_view: true
        )
      end
    end

    # A meeting is a time subject exactly like a ticket (Gespräche Slice 2) — the
    # summary powers the same header chip on the meeting detail.
    context 'with a meeting subject' do
      let(:meeting) { create(:meeting, project: project, organisation: organisation, creator: user) }
      let(:service) { described_class.new(subject: meeting, user: user) }
      let!(:time_permission) do
        create(:time_session_permission,
               user: user,
               project: project,
               can_view_all: true)
      end

      it 'aggregates the meeting sessions like a ticket subject' do
        create(:time_session, meeting: meeting, creator: user, duration: 45, organisation: organisation, project: project)
        create(:time_session, meeting: meeting, creator: other_user, duration: 30, organisation: organisation, project: project)

        result = service.call

        expect(result).to include(
          hours: 1.25,
          scope: :all,
          billing_status: :without_billing,
          can_view: true
        )
      end
    end
  end
end
