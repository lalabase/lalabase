# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MembershipPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  let(:admin_role) { create(:role, title: 'account_admin', organisation: organisation) }
  let(:standard_role) { create(:role, title: 'Standard User', organisation: organisation, is_default: true) }
  let(:other_org_role) { create(:role, title: 'Other Org Role', organisation: other_organisation) }

  let(:admin_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    user
  end

  let(:standard_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: standard_role, active: true)
    user
  end

  let(:other_org_user) do
    user = create(:user)
    create(:membership, user: user, organisation: other_organisation, role: other_org_role, active: true)
    user
  end

  # The membership record being acted upon (another user's membership in the same org)
  let(:target_membership) do
    create(:membership, user: create(:user), organisation: organisation, role: standard_role, active: true)
  end

  let(:other_org_membership) do
    create(:membership, user: create(:user), organisation: other_organisation, role: other_org_role, active: true)
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # ── Edge Case: nil user ──────────────────────────────────────────────

  describe 'without a logged-in user' do
    it 'raises Pundit::NotAuthorizedError' do
      expect { described_class.new(nil, target_membership) }.to raise_error(Pundit::NotAuthorizedError)
    end
  end

  # ── Admin ────────────────────────────────────────────────────────────

  describe 'for admin users' do
    subject { described_class.new(admin_user, target_membership) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:show) }
    it { is_expected.to permit_action(:edit) }
    it { is_expected.to permit_action(:update) }
    it { is_expected.to permit_action(:destroy) }
    it { is_expected.to permit_action(:manage) }

    it { is_expected.not_to permit_action(:create) }
    it { is_expected.not_to permit_action(:new) }
  end

  # ── Admin self-deletion ─────────────────────────────────────────────

  describe 'admin trying to destroy own membership' do
    subject { described_class.new(admin_user, admin_own_membership) }

    let(:admin_own_membership) do
      admin_user.memberships.find_by(organisation: organisation)
    end

    it { is_expected.not_to permit_action(:destroy) }

    it 'still permits other admin actions on own membership' do
      is_expected.to permit_action(:show)
      is_expected.to permit_action(:edit)
      is_expected.to permit_action(:update)
      is_expected.to permit_action(:manage)
    end
  end

  # ── Standard user ───────────────────────────────────────────────────

  describe 'for standard users' do
    subject { described_class.new(standard_user, target_membership) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:show) }

    it { is_expected.not_to permit_action(:edit) }
    it { is_expected.not_to permit_action(:update) }
    it { is_expected.not_to permit_action(:destroy) }
    it { is_expected.not_to permit_action(:manage) }
    it { is_expected.not_to permit_action(:create) }
    it { is_expected.not_to permit_action(:new) }
  end

  # ── Cross-organisation ──────────────────────────────────────────────

  describe 'cross-organisation access' do
    context 'when user views membership from another organisation' do
      subject { described_class.new(standard_user, other_org_membership) }

      it { is_expected.to permit_action(:index) }
      it { is_expected.not_to permit_action(:show) }
      it { is_expected.not_to permit_action(:edit) }
      it { is_expected.not_to permit_action(:update) }
      it { is_expected.not_to permit_action(:destroy) }
      it { is_expected.not_to permit_action(:manage) }
    end

    context 'when admin views membership from another organisation' do
      subject { described_class.new(admin_user, other_org_membership) }

      it 'denies admin actions because admin status is org-scoped' do
        is_expected.not_to permit_action(:show)
        is_expected.not_to permit_action(:edit)
        is_expected.not_to permit_action(:update)
        is_expected.not_to permit_action(:destroy)
        is_expected.not_to permit_action(:manage)
      end
    end
  end

  # ── Scope ───────────────────────────────────────────────────────────

  describe MembershipPolicy::Scope do
    let!(:same_org_membership) { target_membership }
    let!(:different_org_membership) { other_org_membership }

    context 'with current tenant set' do
      let(:project) { create(:project, organisation: organisation) }
      let!(:collaborator_membership) do
        u = create(:user)
        create(:project_permission, user: u, project: project, tickets_access: 'read_only')
        create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
      end

      before do
        create(:project_permission, user: standard_user, project: project, tickets_access: 'read_only')
      end

      it 'returns the full org roster for an admin' do
        result = described_class.new(admin_user, Membership).resolve
        expect(result).to include(same_org_membership, collaborator_membership)
        expect(result).not_to include(different_org_membership)
      end

      it 'includes the user themselves and collaborators on their projects' do
        result = described_class.new(standard_user, Membership).resolve
        expect(result.map(&:user_id)).to include(standard_user.id, collaborator_membership.user_id)
      end

      it 'excludes members the standard user shares no accessible project with' do
        # same_org_membership belongs to an unrelated member (no shared project)
        result = described_class.new(standard_user, Membership).resolve
        expect(result).not_to include(same_org_membership)
      end

      it 'excludes memberships from other organisations' do
        result = described_class.new(standard_user, Membership).resolve
        expect(result).not_to include(different_org_membership)
      end
    end

    context 'without current tenant' do
      before { ActsAsTenant.current_tenant = nil }

      it 'returns memberships from all organisations the user belongs to' do
        result = described_class.new(standard_user, Membership).resolve
        expect(result).to include(same_org_membership)
        expect(result).not_to include(different_org_membership)
      end
    end

    context 'for user with memberships in multiple organisations' do
      before do
        create(:membership, user: standard_user, organisation: other_organisation,
                            role: other_org_role, active: true)
        ActsAsTenant.current_tenant = nil
      end

      it 'returns memberships from all organisations the user belongs to' do
        result = described_class.new(standard_user, Membership).resolve
        expect(result).to include(same_org_membership)
        expect(result).to include(different_org_membership)
      end
    end
  end
end
