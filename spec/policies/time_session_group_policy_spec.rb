# frozen_string_literal: true

require 'rails_helper'
require 'pundit/rspec'

RSpec.describe TimeSessionGroupPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:admin_user) { create(:user) }
  let(:finance_user) { create(:user) }
  let(:regular_user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:time_session_group) { create(:time_session_group, organisation: organisation, creator: admin_user) }

  before do
    # Set the tenant for ActsAsTenant
    ActsAsTenant.current_tenant = organisation

    # Setup roles
    admin_role = create(:role, title: 'account_admin', organisation: organisation)
    finance_role = create(:role, title: 'Finance', organisation: organisation)
    member_role = create(:role, title: 'member', organisation: organisation)

    # Setup memberships
    create(:membership, user: admin_user, organisation: organisation, role: admin_role)
    create(:membership, user: finance_user, organisation: organisation, role: finance_role)
    create(:membership, user: regular_user, organisation: organisation, role: member_role)
    create(:membership, user: other_user, organisation: organisation, role: member_role)

    # Setup TimeSessionPermissions for regular_user
    create(:time_session_permission, user: regular_user, project: project, can_view_all: true)
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  subject { described_class }

  permissions :index? do
    it 'grants access to admin users' do
      expect(subject).to permit(admin_user, time_session_group)
    end

    it 'grants access to finance users' do
      expect(subject).to permit(finance_user, time_session_group)
    end

    it 'denies access to regular users without time sessions' do
      expect(subject).not_to permit(regular_user, time_session_group)
    end
  end

  permissions :show? do
    context 'when user is admin' do
      it 'grants access' do
        expect(subject).to permit(admin_user, time_session_group)
      end
    end

    context 'when user has finance role' do
      it 'grants access' do
        expect(subject).to permit(finance_user, time_session_group)
      end
    end

    context 'when user has time sessions in the group' do
      before do
        create(:time_session,
               time_session_group: time_session_group,
               project: project,
               creator: regular_user,
               organisation: organisation)
      end

      it 'grants access' do
        expect(subject).to permit(regular_user, time_session_group)
      end
    end

    context 'when user has no time sessions in the group' do
      it 'denies access' do
        expect(subject).not_to permit(other_user, time_session_group)
      end
    end
  end

  permissions :create? do
    it 'grants access to admin users' do
      expect(subject).to permit(admin_user, time_session_group)
    end

    it 'grants access to finance users' do
      expect(subject).to permit(finance_user, time_session_group)
    end

    it 'denies access to regular users' do
      expect(subject).not_to permit(regular_user, time_session_group)
    end
  end

  permissions :update? do
    it 'grants access to admin users' do
      expect(subject).to permit(admin_user, time_session_group)
    end

    it 'grants access to finance users' do
      expect(subject).to permit(finance_user, time_session_group)
    end

    it 'grants access to the creator' do
      group_by_regular_user = create(:time_session_group, organisation: organisation, creator: regular_user)
      expect(subject).to permit(regular_user, group_by_regular_user)
    end

    it 'denies access to non-creators without special roles' do
      expect(subject).not_to permit(regular_user, time_session_group)
    end
  end

  permissions :destroy? do
    it 'grants access only to admin users' do
      expect(subject).to permit(admin_user, time_session_group)
    end

    it 'denies access to finance users' do
      expect(subject).not_to permit(finance_user, time_session_group)
    end

    it 'denies access to regular users' do
      expect(subject).not_to permit(regular_user, time_session_group)
    end

    it 'denies access even to creators' do
      group_by_regular_user = create(:time_session_group, organisation: organisation, creator: regular_user)
      expect(subject).not_to permit(regular_user, group_by_regular_user)
    end
  end

  describe TimeSessionGroupPolicy::Scope do
    let!(:admin_group) { create(:time_session_group, organisation: organisation, creator: admin_user) }
    let!(:finance_group) { create(:time_session_group, organisation: organisation, creator: finance_user) }
    let!(:user_group) { create(:time_session_group, organisation: organisation, creator: regular_user) }

    context 'for admin users' do
      it 'returns all groups' do
        scope = described_class.new(admin_user, TimeSessionGroup.where(organisation: organisation))
        expect(scope.resolve).to include(admin_group, finance_group, user_group)
      end
    end

    context 'for finance users' do
      it 'returns all groups' do
        scope = described_class.new(finance_user, TimeSessionGroup.where(organisation: organisation))
        expect(scope.resolve).to include(admin_group, finance_group, user_group)
      end
    end

    context 'for regular users' do
      context 'with time sessions in groups' do
        before do
          create(:time_session,
                 time_session_group: admin_group,
                 project: project,
                 creator: regular_user,
                 organisation: organisation)
        end

        it 'returns only groups with their time sessions' do
          scope = described_class.new(regular_user, TimeSessionGroup.where(organisation: organisation))
          expect(scope.resolve).to include(admin_group)
          expect(scope.resolve).not_to include(finance_group, user_group)
        end
      end

      context 'without time sessions' do
        it 'returns no groups' do
          scope = described_class.new(other_user, TimeSessionGroup.where(organisation: organisation))
          expect(scope.resolve).to be_empty
        end
      end
    end
  end

  # ===========================================================================
  # Edge Case Tests
  # ===========================================================================

  describe 'authentication edge cases' do
    it 'raises Pundit::NotAuthorizedError for nil user on policy' do
      expect { described_class.new(nil, time_session_group) }.to raise_error(Pundit::NotAuthorizedError)
    end

    it 'raises Pundit::NotAuthorizedError for nil user on scope' do
      expect { TimeSessionGroupPolicy::Scope.new(nil, TimeSessionGroup.all) }.to raise_error(Pundit::NotAuthorizedError)
    end
  end

  describe 'new? / edit? delegation' do
    it 'admin can new? (delegates to create?)' do
      policy = described_class.new(admin_user, time_session_group)
      expect(policy.new?).to be true
    end

    it 'finance can new? (delegates to create?)' do
      policy = described_class.new(finance_user, time_session_group)
      expect(policy.new?).to be true
    end

    it 'regular user cannot new?' do
      policy = described_class.new(regular_user, time_session_group)
      expect(policy.new?).to be false
    end

    it 'admin can edit? (delegates to update?)' do
      policy = described_class.new(admin_user, time_session_group)
      expect(policy.edit?).to be true
    end

    it 'creator can edit? (delegates to update?)' do
      group = create(:time_session_group, organisation: organisation, creator: regular_user)
      policy = described_class.new(regular_user, group)
      expect(policy.edit?).to be true
    end

    it 'non-creator regular user cannot edit?' do
      policy = described_class.new(regular_user, time_session_group)
      expect(policy.edit?).to be false
    end
  end

  describe 'delegated action methods' do
    describe 'mark_as_billed? (delegates to create?)' do
      it 'admin can mark_as_billed' do
        policy = described_class.new(admin_user, time_session_group)
        expect(policy.mark_as_billed?).to be true
      end

      it 'finance can mark_as_billed' do
        policy = described_class.new(finance_user, time_session_group)
        expect(policy.mark_as_billed?).to be true
      end

      it 'creator cannot mark_as_billed (create? required, not update?)' do
        group = create(:time_session_group, organisation: organisation, creator: regular_user)
        policy = described_class.new(regular_user, group)
        expect(policy.mark_as_billed?).to be false
      end
    end

    describe 'generate_customer_descriptions? (delegates to update?)' do
      it 'admin can generate' do
        policy = described_class.new(admin_user, time_session_group)
        expect(policy.generate_customer_descriptions?).to be true
      end

      it 'creator can generate' do
        group = create(:time_session_group, organisation: organisation, creator: regular_user)
        policy = described_class.new(regular_user, group)
        expect(policy.generate_customer_descriptions?).to be true
      end

      it 'non-creator regular user cannot generate' do
        policy = described_class.new(regular_user, time_session_group)
        expect(policy.generate_customer_descriptions?).to be false
      end
    end

    describe 'export_customer_descriptions? (delegates to show?)' do
      it 'admin can export' do
        policy = described_class.new(admin_user, time_session_group)
        expect(policy.export_customer_descriptions?).to be true
      end

      it 'user with time sessions in group can export' do
        create(:time_session,
               time_session_group: time_session_group,
               project: project,
               creator: regular_user,
               organisation: organisation)
        policy = described_class.new(regular_user, time_session_group)
        expect(policy.export_customer_descriptions?).to be true
      end

      it 'user without access cannot export' do
        policy = described_class.new(other_user, time_session_group)
        expect(policy.export_customer_descriptions?).to be false
      end
    end

    describe 'chronological? / aggregated? / customer_export? (delegate to show?)' do
      it 'admin can access all view variants' do
        policy = described_class.new(admin_user, time_session_group)
        expect(policy.chronological?).to be true
        expect(policy.aggregated?).to be true
        expect(policy.customer_export?).to be true
      end

      it 'user without access is denied all view variants' do
        policy = described_class.new(other_user, time_session_group)
        expect(policy.chronological?).to be false
        expect(policy.aggregated?).to be false
        expect(policy.customer_export?).to be false
      end
    end
  end

  describe 'destroy? asymmetry' do
    it 'finance user cannot destroy (only admin can)' do
      policy = described_class.new(finance_user, time_session_group)
      expect(policy.destroy?).to be false
    end

    it 'creator cannot destroy their own group' do
      group = create(:time_session_group, organisation: organisation, creator: regular_user)
      policy = described_class.new(regular_user, group)
      expect(policy.destroy?).to be false
    end

    it 'admin can destroy any group' do
      group = create(:time_session_group, organisation: organisation, creator: regular_user)
      policy = described_class.new(admin_user, group)
      expect(policy.destroy?).to be true
    end
  end

  describe 'create? with class vs instance record' do
    it 'allows admin to create? when record is the class (new action context)' do
      policy = described_class.new(admin_user, TimeSessionGroup)
      expect(policy.create?).to be true
    end

    it 'allows finance to create? when record is the class' do
      policy = described_class.new(finance_user, TimeSessionGroup)
      expect(policy.create?).to be true
    end

    it 'denies regular user create? when record is the class' do
      policy = described_class.new(regular_user, TimeSessionGroup)
      expect(policy.create?).to be false
    end

    it 'allows admin to create? when record is an instance' do
      policy = described_class.new(admin_user, time_session_group)
      expect(policy.create?).to be true
    end
  end

  describe 'cross-tenant isolation' do
    let(:other_organisation) { create(:organisation) }

    let(:other_member_role) do
      ActsAsTenant.with_tenant(other_organisation) do
        create(:role, title: 'member', organisation: other_organisation)
      end
    end

    let(:other_admin_role) do
      ActsAsTenant.with_tenant(other_organisation) do
        create(:role, title: 'account_admin', organisation: other_organisation)
      end
    end

    let(:outsider_user) do
      user = create(:user)
      create(:membership, user: user, organisation: other_organisation, role: other_member_role, active: true)
      user
    end

    let(:other_admin_user) do
      user = create(:user)
      create(:membership, user: user, organisation: other_organisation, role: other_admin_role, active: true)
      user
    end

    context 'user without membership in group organisation' do
      it 'denies index?' do
        policy = described_class.new(outsider_user, time_session_group)
        expect(policy.index?).to be false
      end

      it 'denies show?' do
        policy = described_class.new(outsider_user, time_session_group)
        expect(policy.show?).to be false
      end

      it 'denies create?' do
        policy = described_class.new(outsider_user, time_session_group)
        expect(policy.create?).to be false
      end

      it 'denies destroy?' do
        policy = described_class.new(outsider_user, time_session_group)
        # Returns nil (falsy) because account_admin_in? → role_in_organisation
        # returns nil when user has no membership in this org
        expect(policy.destroy?).to be_falsey
      end
    end

    context 'admin of a different organisation' do
      it 'denies all actions on groups in current tenant' do
        policy = described_class.new(other_admin_user, time_session_group)
        expect(policy.index?).to be false
        expect(policy.show?).to be false
        expect(policy.create?).to be false
        expect(policy.destroy?).to be_falsey
      end
    end

    it 'scope returns only groups from the current tenant' do
      other_group = ActsAsTenant.with_tenant(other_organisation) do
        other_creator = create(:user)
        create(:membership, user: other_creator, organisation: other_organisation, role: other_member_role)
        create(:time_session_group, organisation: other_organisation, creator: other_creator)
      end

      scope = TimeSessionGroupPolicy::Scope.new(admin_user, TimeSessionGroup.all).resolve
      expect(scope).to include(time_session_group)
      expect(scope).not_to include(other_group)
    end
  end

  describe 'inactive memberships' do
    # Roles are already created in the top-level before block; reuse via find_by
    let(:inactive_admin_user) do
      user = create(:user)
      role = Role.find_by!(title: 'account_admin', organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: false)
      user
    end

    let(:inactive_finance_user) do
      user = create(:user)
      role = Role.find_by!(title: 'Finance', organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: false)
      user
    end

    let(:inactive_regular_user) do
      user = create(:user)
      role = Role.find_by!(title: 'member', organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: false)
      user
    end

    context 'inactive admin — policy actions' do
      # Used to read "Inactive admin retains all permissions", because
      # account_admin_in? → role_in_organisation looked up the membership without
      # filtering by active. Closed in #603: the authorisation question now requires an
      # active membership, while role_in_organisation still answers the master-data
      # question ("which role does this person hold here") unchanged.
      it 'cannot index? (account_admin_in? requires an active membership)' do
        policy = described_class.new(inactive_admin_user, time_session_group)
        expect(policy.index?).to be false
      end

      it 'cannot show?' do
        policy = described_class.new(inactive_admin_user, time_session_group)
        expect(policy.show?).to be false
      end

      it 'cannot create?' do
        policy = described_class.new(inactive_admin_user, time_session_group)
        expect(policy.create?).to be false
      end

      it 'cannot destroy?' do
        policy = described_class.new(inactive_admin_user, time_session_group)
        expect(policy.destroy?).to be false
      end
    end

    context 'inactive admin — scope' do
      # The flow anchor for the negative below: an ACTIVE admin does get the group, so
      # an empty scope is the deactivation talking and not a broken fixture.
      it 'returns the group for an ACTIVE admin' do
        scope = TimeSessionGroupPolicy::Scope.new(admin_user, TimeSessionGroup.all).resolve
        expect(scope).to include(time_session_group)
      end

      it 'returns nothing once the admin membership is deactivated' do
        scope = TimeSessionGroupPolicy::Scope.new(inactive_admin_user, TimeSessionGroup.all).resolve
        expect(scope).not_to include(time_session_group)
      end
    end

    context 'inactive finance user — policy actions' do
      # SECURITY NOTE: has_finance_role_for_organisation? queries
      # user.memberships.joins(:role).where(organisation:, roles: { title: ... })
      # without filtering by active. Inactive finance user retains permissions.
      it 'can index? (finance role check does not filter by active)' do
        policy = described_class.new(inactive_finance_user, time_session_group)
        expect(policy.index?).to be true
      end

      it 'can show?' do
        policy = described_class.new(inactive_finance_user, time_session_group)
        expect(policy.show?).to be true
      end

      it 'can create?' do
        policy = described_class.new(inactive_finance_user, time_session_group)
        expect(policy.create?).to be true
      end

      it 'cannot destroy? (only admin, not finance)' do
        policy = described_class.new(inactive_finance_user, time_session_group)
        expect(policy.destroy?).to be false
      end
    end

    context 'inactive finance user — scope' do
      it 'returns all groups (finance check does not filter by active)' do
        # SECURITY NOTE: Scope finance check also lacks active filter.
        scope = TimeSessionGroupPolicy::Scope.new(inactive_finance_user, TimeSessionGroup.all).resolve
        expect(scope).to include(time_session_group)
      end
    end

    context 'inactive regular user with time sessions in group' do
      before do
        create(:time_session,
               time_session_group: time_session_group,
               project: project,
               creator: inactive_regular_user,
               organisation: organisation)
      end

      it 'can show? via has_time_sessions_in_group? (no active check on creator query)' do
        # SECURITY NOTE: has_time_sessions_in_group? checks
        # record.time_sessions.where(creator_id: user.id) — no membership active check.
        policy = described_class.new(inactive_regular_user, time_session_group)
        expect(policy.show?).to be true
      end

      it 'cannot index? (not admin or finance)' do
        policy = described_class.new(inactive_regular_user, time_session_group)
        expect(policy.index?).to be false
      end

      it 'cannot create?' do
        policy = described_class.new(inactive_regular_user, time_session_group)
        expect(policy.create?).to be false
      end
    end
  end

  describe 'show? via TimeSessionPermission (can_view_all)' do
    let(:permission_user) do
      user = create(:user)
      role = Role.find_by!(title: 'member', organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      user
    end

    let(:group_with_sessions) do
      group = create(:time_session_group, organisation: organisation, creator: admin_user)
      create(:time_session,
             time_session_group: group,
             project: project,
             creator: admin_user,
             organisation: organisation)
      group
    end

    context 'user with can_view_all on project in the group' do
      before do
        create(:time_session_permission,
               user: permission_user,
               project: project,
               can_view_all: true)
      end

      it 'can show? the group' do
        policy = described_class.new(permission_user, group_with_sessions)
        expect(policy.show?).to be true
      end

      it 'can export_customer_descriptions? (delegates to show?)' do
        policy = described_class.new(permission_user, group_with_sessions)
        expect(policy.export_customer_descriptions?).to be true
      end
    end

    context 'user with can_view_own but NOT can_view_all' do
      before do
        create(:time_session_permission,
               user: permission_user,
               project: project,
               can_view_own: true,
               can_view_all: false)
      end

      it 'cannot show? the group (can_view_all required, not can_view_own)' do
        policy = described_class.new(permission_user, group_with_sessions)
        expect(policy.show?).to be false
      end
    end

    context 'user without any TimeSessionPermission' do
      it 'cannot show? the group' do
        policy = described_class.new(permission_user, group_with_sessions)
        expect(policy.show?).to be false
      end
    end
  end

  describe 'scope edge cases' do
    it 'returns empty for user without any permissions or time sessions' do
      scope = TimeSessionGroupPolicy::Scope.new(other_user, TimeSessionGroup.all).resolve
      expect(scope).to be_empty
    end

    it 'includes groups via can_view_all TimeSessionPermission' do
      viewer = create(:user)
      role = Role.find_by!(title: 'member', organisation: organisation)
      create(:membership, user: viewer, organisation: organisation, role: role, active: true)

      group = create(:time_session_group, organisation: organisation, creator: admin_user)
      create(:time_session,
             time_session_group: group,
             project: project,
             creator: admin_user,
             organisation: organisation)
      create(:time_session_permission, user: viewer, project: project, can_view_all: true)

      scope = TimeSessionGroupPolicy::Scope.new(viewer, TimeSessionGroup.all).resolve
      expect(scope).to include(group)
    end

    it 'empty group (no time sessions) is not visible to regular users' do
      empty_group = create(:time_session_group, organisation: organisation, creator: admin_user)

      scope = TimeSessionGroupPolicy::Scope.new(regular_user, TimeSessionGroup.all).resolve
      expect(scope).not_to include(empty_group)
    end

    it 'group with sessions from multiple projects — user sees it if they created one session' do
      project2 = create(:project, organisation: organisation)
      group = create(:time_session_group, organisation: organisation, creator: admin_user)
      create(:time_session, time_session_group: group, project: project,
                            creator: admin_user, organisation: organisation)
      create(:time_session, time_session_group: group, project: project2,
                            creator: regular_user, organisation: organisation)

      scope = TimeSessionGroupPolicy::Scope.new(regular_user, TimeSessionGroup.all).resolve
      expect(scope).to include(group)
    end

    it 'returns none when no tenant is set' do
      ActsAsTenant.current_tenant = nil
      # Use without_tenant to bypass acts_as_tenant default_scope on TimeSessionGroup.all
      scope = ActsAsTenant.without_tenant do
        TimeSessionGroupPolicy::Scope.new(admin_user, TimeSessionGroup.all).resolve
      end
      expect(scope).to be_empty
      ActsAsTenant.current_tenant = organisation
    end
  end

  describe 'defensive edge cases' do
    it 'index? returns false when no tenant is set' do
      # Ensure time_session_group is loaded before clearing tenant
      time_session_group
      ActsAsTenant.current_tenant = nil
      policy = described_class.new(admin_user, time_session_group)
      expect(policy.index?).to be false
      ActsAsTenant.current_tenant = organisation
    end

    it 'user who is admin in org A but regular in org B follows org B rights' do
      org_b = create(:organisation)
      member_role_b = ActsAsTenant.with_tenant(org_b) do
        create(:role, title: 'member', organisation: org_b)
      end
      create(:membership, user: admin_user, organisation: org_b, role: member_role_b, active: true)

      group_b = ActsAsTenant.with_tenant(org_b) do
        creator_b = create(:user)
        create(:membership, user: creator_b, organisation: org_b, role: member_role_b)
        create(:time_session_group, organisation: org_b, creator: creator_b)
      end

      # Switch tenant to org B where admin_user is just a regular member
      ActsAsTenant.current_tenant = org_b
      policy = described_class.new(admin_user, group_b)

      expect(policy.index?).to be false
      expect(policy.create?).to be false
      expect(policy.destroy?).to be false

      ActsAsTenant.current_tenant = organisation
    end

    it 'creator check works correctly when user is creator but not admin/finance' do
      group = create(:time_session_group, organisation: organisation, creator: regular_user)
      policy = described_class.new(regular_user, group)

      # Creator can update and generate but not create/destroy/mark_as_billed
      expect(policy.update?).to be true
      expect(policy.generate_customer_descriptions?).to be true
      expect(policy.create?).to be false
      expect(policy.destroy?).to be false
      expect(policy.mark_as_billed?).to be false
    end
  end
  # Pundit derives the question from the ACTION name, so a new action needs its
  # own predicate or it raises NoMethodError at request time rather than failing
  # a check. entries? is show? and must stay that way: it is the same data in a
  # smaller frame, and a second answer to one question is how the two drift.
  describe '#entries?' do
    it 'answers exactly what show? answers, whoever is asking' do
      [admin_user, finance_user, regular_user].each do |candidate|
        policy = described_class.new(candidate, time_session_group)

        expect(policy.entries?).to eq(policy.show?)
      end
    end
  end
end
