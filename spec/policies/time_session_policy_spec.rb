# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TimeSessionPolicy, :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:admin) { create(:user) }
  let(:time_session) { create(:time_session, project: project, creator: user) }
  let(:other_time_session) { create(:time_session, project: project, creator: other_user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
    create(:membership, user: other_user, organisation: organisation)
    admin_role = create(:role, title: 'account_admin', organisation: organisation)
    create(:membership, user: admin, organisation: organisation, role: admin_role)
  end

  # The list itself (record is the class). One owner with the menu gate and
  # the sidebar block: TimeSessions::ViewingScope#sees_anything?. A row that
  # grants no viewing flag opened the list before (mere existence counted).
  describe '#index? for the list (record is the class)' do
    it 'is true for an account admin without any permission row' do
      expect(described_class.new(admin, TimeSession).index?).to be true
    end

    it 'is true with a row that grants can_view_own' do
      create(:time_session_permission, user: user, project: project, can_view_own: true, can_view_all: false)

      expect(described_class.new(user, TimeSession).index?).to be true
    end

    it 'is false with a row that grants no viewing flag' do
      create(:time_session_permission, user: user, project: project, can_view_own: false, can_view_all: false)

      expect(described_class.new(user, TimeSession).index?).to be false
    end

    it 'is false without any row' do
      expect(described_class.new(user, TimeSession).index?).to be false
    end
  end

  describe '#show?' do
    context 'as admin' do
      it 'allows viewing own sessions without permission record' do
        policy = described_class.new(admin, time_session)
        expect(policy.show?).to be true
      end

      it 'allows viewing other users sessions without permission record' do
        policy = described_class.new(admin, other_time_session)
        expect(policy.show?).to be true
      end
    end

    context 'with own time session' do
      let(:permission) { create(:time_session_permission, user: user, project: project) }

      it 'allows viewing when can_view_own is true' do
        permission.update!(can_view_own: true)
        policy = described_class.new(user, time_session)
        expect(policy.show?).to be true
      end

      it 'denies viewing when can_view_own is false' do
        permission.update!(can_view_own: false)
        policy = described_class.new(user, time_session)
        expect(policy.show?).to be false
      end
    end

    context 'with other users time session' do
      let(:permission) { create(:time_session_permission, user: user, project: project) }

      it 'allows viewing when can_view_all is true' do
        permission.update!(can_view_all: true)
        policy = described_class.new(user, other_time_session)
        expect(policy.show?).to be true
      end

      it 'denies viewing when can_view_all is false' do
        permission.update!(can_view_all: false)
        policy = described_class.new(user, other_time_session)
        expect(policy.show?).to be false
      end
    end
  end

  describe '#create?' do
    let(:new_session) { build(:time_session, project: project) }
    let(:permission) { create(:time_session_permission, user: user, project: project) }

    context 'as admin' do
      it 'allows creation without permission record' do
        policy = described_class.new(admin, new_session)
        expect(policy.create?).to be true
      end
    end

    it 'allows creation when can_create_own is true' do
      permission.update!(can_create_own: true)
      policy = described_class.new(user, new_session)
      expect(policy.create?).to be true
    end

    it 'denies creation when can_create_own is false' do
      permission.update!(can_create_own: false)
      policy = described_class.new(user, new_session)
      expect(policy.create?).to be false
    end

    it 'denies creation without permission record' do
      permission.destroy
      policy = described_class.new(user, new_session)
      expect(policy.create?).to be false
    end
  end

  describe '#update?' do
    let(:permission) { create(:time_session_permission, user: user, project: project) }

    context 'as admin' do
      it 'allows updating own sessions without permission record' do
        policy = described_class.new(admin, time_session)
        expect(policy.update?).to be true
      end

      it 'allows updating other users sessions without permission record' do
        policy = described_class.new(admin, other_time_session)
        expect(policy.update?).to be true
      end
    end

    context 'with own time session' do
      it 'allows editing when can_edit_own is true' do
        permission.update!(can_edit_own: true)
        policy = described_class.new(user, time_session)
        expect(policy.update?).to be true
      end

      it 'denies editing when can_edit_own is false' do
        permission.update!(can_edit_own: false)
        policy = described_class.new(user, time_session)
        expect(policy.update?).to be false
      end
    end

    context 'with other users time session' do
      it 'allows editing when can_edit_all is true' do
        permission.update!(can_edit_all: true)
        policy = described_class.new(user, other_time_session)
        expect(policy.update?).to be true
      end

      it 'denies editing when can_edit_all is false' do
        permission.update!(can_edit_all: false)
        policy = described_class.new(user, other_time_session)
        expect(policy.update?).to be false
      end
    end
  end

  describe '#destroy?' do
    let(:permission) { create(:time_session_permission, user: user, project: project) }

    context 'as regular user' do
      context 'with own time session' do
        it 'allows deletion when can_delete_own is true' do
          permission.update!(can_delete_own: true)
          policy = described_class.new(user, time_session)
          expect(policy.destroy?).to be true
        end

        it 'denies deletion when can_delete_own is false' do
          permission.update!(can_delete_own: false)
          policy = described_class.new(user, time_session)
          expect(policy.destroy?).to be false
        end
      end

      context 'with other users time session' do
        it 'allows deletion when can_delete_all is true' do
          permission.update!(can_delete_all: true)
          policy = described_class.new(user, other_time_session)
          expect(policy.destroy?).to be true
        end

        it 'denies deletion when can_delete_all is false' do
          permission.update!(can_delete_all: false)
          policy = described_class.new(user, other_time_session)
          expect(policy.destroy?).to be false
        end
      end
    end

    context 'as admin' do
      it 'always allows deletion' do
        policy = described_class.new(admin, other_time_session)
        expect(policy.destroy?).to be true
      end
    end
  end

  describe 'Scope' do
    let!(:permission) { create(:time_session_permission, user: user, project: project) }
    let!(:my_session) { create(:time_session, project: project, creator: user) }
    let!(:other_session) { create(:time_session, project: project, creator: other_user) }

    context 'as admin' do
      it 'returns all time sessions' do
        scope = described_class::Scope.new(admin, TimeSession.all).resolve
        expect(scope).to include(my_session, other_session)
      end
    end

    context 'as regular user' do
      it 'returns only own sessions when can_view_own is true and can_view_all is false' do
        permission.update!(can_view_own: true, can_view_all: false)
        scope = described_class::Scope.new(user, TimeSession.all).resolve
        expect(scope).to include(my_session)
        expect(scope).not_to include(other_session)
      end

      it 'returns all sessions when can_view_all is true' do
        permission.update!(can_view_all: true)
        scope = described_class::Scope.new(user, TimeSession.all).resolve
        expect(scope).to include(my_session, other_session)
      end

      it 'returns no sessions when both permissions are false' do
        permission.update!(can_view_own: false, can_view_all: false)
        scope = described_class::Scope.new(user, TimeSession.all).resolve
        expect(scope).to be_empty
      end
    end

    # S0 (doc/projektzeiten_tabelle_plan.md): this scope used to carry its own copy
    # of the visibility rule, and that copy knew nothing about deactivated
    # memberships. ProjectPolicy#area_access? and TimeSessions::ViewingScope both
    # refuse them, so a stale permission row behind a switched-off membership
    # granted more time here than anywhere else in the app.
    context 'with a deactivated membership' do
      it 'returns nothing despite a can_view_all row' do
        permission.update!(can_view_all: true)
        user.memberships.find_by(organisation: organisation).update!(active: false)

        expect(described_class::Scope.new(user, TimeSession.all).resolve).to be_empty
      end

      it 'returns nothing despite an account_admin role' do
        user.memberships.find_by(organisation: organisation).update!(
          role: Role.find_by!(organisation: organisation, title: 'account_admin'), active: false
        )

        expect(described_class::Scope.new(user, TimeSession.all).resolve).to be_empty
      end
    end

    # Fail-closed at the other end: without a tenant there is no organisation to
    # decide against. Mutation: return scope.all instead of scope.none there, and
    # a job or a console session outside a tenant sees every organisation's hours.
    it 'returns nothing when there is no tenant to decide against' do
      relation = TimeSession.all
      scope = ActsAsTenant.without_tenant { described_class::Scope.new(user, relation) }

      expect(scope.resolve.to_a).to eq([])
    end

    # The old #resolve read the organisation off `scope.first`, which loaded a row
    # before it could decide anything -- on every dashboard tile, briefing and list.
    # The tenant already knows which organisation this is.
    it 'decides without loading a time session first' do
      statements = capture_sql { described_class::Scope.new(user, TimeSession.all).resolve }

      expect(statements.grep(/FROM "time_sessions"/)).to be_empty
    end
  end
end
