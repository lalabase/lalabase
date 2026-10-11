# frozen_string_literal: true

require 'rails_helper'

# What: DocumentationSetPolicy — the Scope's three access paths (admin, org-wide
#       role grant, per-project permission) and read/write instance gating.
# Type: Policy spec.
# Why:  The per-project-permission Scope branch is otherwise only reachable via a
#       per-project grant, which the request specs (role-based) never exercise —
#       a mutation in that branch would silently hide or leak sets.
RSpec.describe DocumentationSetPolicy, :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:set) { create(:documentation_set, project: project) }

  before { ActsAsTenant.current_tenant = organisation }

  def make_account_admin
    role = create(:role, organisation: organisation, title: 'account_admin')
    create(:membership, user: user, organisation: organisation, role: role, active: true)
  end

  def grant_org_wide(action)
    role = create(:role, organisation: organisation, title: "role_#{action}")
    Permission.create!(role: role, category: 'projects', action: action, allowed: true)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
  end

  describe 'Scope' do
    subject(:resolved) { DocumentationSetPolicy::Scope.new(user, DocumentationSet.all).resolve }

    it 'returns nothing for a user without any documentation access' do
      set
      expect(resolved).to be_empty
    end

    it 'returns every set for an account admin' do
      make_account_admin
      expect(resolved).to include(set)
    end

    it 'returns every set for a holder of the org-wide role grant' do
      grant_org_wide('read_access_documentation_all_projects')
      expect(resolved).to include(set)
    end

    context 'with only a per-project permission' do
      let(:other_project) { create(:project, organisation: organisation) }
      let!(:other_set) { create(:documentation_set, project: other_project) }

      before do
        create(:project_permission, user: user, project: project, documentation_access: :read_only)
      end

      it 'includes sets of the permitted project' do
        expect(resolved).to include(set)
      end

      it 'excludes sets of projects the user has no permission in' do
        expect(resolved).not_to include(other_set)
      end

      it 'ignores an explicit no_access permission' do
        ProjectPermission.find_by(user: user, project: project).update!(documentation_access: :no_access)
        expect(resolved).not_to include(set)
      end

      # The Scope relies on ProjectPermission's soft-delete default_scope; a
      # query via .unscoped/.with_deleted would let revoked users keep seeing sets.
      it 'ignores a revoked (soft-deleted) permission' do
        ProjectPermission.find_by(user: user, project: project).update!(deleted_at: Time.current)
        expect(resolved).not_to include(set)
      end
    end
  end

  describe 'instance gating' do
    let(:policy) { described_class.new(user, set) }

    # area_access? additionally requires active org membership (the Scope does
    # not — it works off ProjectPermission rows). Grant a bare membership so the
    # per-project documentation permission is what actually decides.
    before do
      member_role = create(:role, organisation: organisation, title: 'member')
      create(:membership, user: user, organisation: organisation, role: member_role, active: true)
    end

    context 'with per-project read_only' do
      before { create(:project_permission, user: user, project: project, documentation_access: :read_only) }

      it 'permits reading but not managing/syncing' do
        expect(policy.index?).to be(true)
        expect(policy.show?).to be(true)
        expect(policy.create?).to be(false)
        expect(policy.sync?).to be(false)
        expect(policy.destroy?).to be(false)
      end
    end

    context 'with per-project read_write' do
      before { create(:project_permission, user: user, project: project, documentation_access: :read_write) }

      it 'permits reading and managing/syncing' do
        expect(policy.index?).to be(true)
        expect(policy.create?).to be(true)
        expect(policy.sync?).to be(true)
        expect(policy.destroy?).to be(true)
      end
    end

    context 'with no access' do
      it 'permits nothing' do
        expect(policy.index?).to be(false)
        expect(policy.sync?).to be(false)
      end
    end

    # The controller authorizes create? against the PROJECT (no set exists yet);
    # the policy's `project` helper must handle both record shapes.
    context 'with the project itself as the record' do
      it 'gates create? by the documentation write permission' do
        create(:project_permission, user: user, project: project, documentation_access: :read_only)
        expect(described_class.new(user, project).create?).to be(false)

        ProjectPermission.find_by(user: user, project: project).update!(documentation_access: :read_write)
        expect(described_class.new(user, project).create?).to be(true)
      end
    end
  end
end
