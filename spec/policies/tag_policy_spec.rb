# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TagPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  let(:admin_role) { create(:role, title: 'account_admin', organisation: organisation) }
  let(:standard_role) { create(:role, title: 'Standard User', organisation: organisation, is_default: true) }

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
    other_role = create(:role, title: 'Other Org Role', organisation: other_organisation)
    user = create(:user)
    create(:membership, user: user, organisation: other_organisation, role: other_role, active: true)
    user
  end

  # Tags
  let(:owned_tag) do
    create(:tag, organisation: organisation, user_id: standard_user.id)
  end

  let(:other_users_tag) do
    create(:tag, organisation: organisation, user_id: admin_user.id)
  end

  let(:unowned_tag) do
    create(:tag, organisation: organisation, user_id: nil)
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # ── Nil user ────────────────────────────────────────────────────────

  describe 'without a logged-in user' do
    it 'raises Pundit::NotAuthorizedError' do
      expect { described_class.new(nil, owned_tag) }.to raise_error(Pundit::NotAuthorizedError)
    end
  end

  # ── index? / show? — immer true ─────────────────────────────────────

  describe '#index?' do
    it 'permits any authenticated user' do
      expect(described_class.new(standard_user, owned_tag).index?).to be true
      expect(described_class.new(admin_user, owned_tag).index?).to be true
      expect(described_class.new(other_org_user, owned_tag).index?).to be true
    end
  end

  describe '#show?' do
    let(:project) { create(:project, organisation: organisation) }
    let(:accessible_tag) do
      tag = create(:tag, organisation: organisation)
      create(:tagging, tag: tag, taggable: create(:ticket, project: project, organisation: organisation))
      tag
    end

    before do
      create(:project_permission, user: standard_user, project: project, tickets_access: 'read_only')
    end

    it 'permits an admin to see any tag' do
      expect(described_class.new(admin_user, accessible_tag).show?).to be true
      expect(described_class.new(admin_user, owned_tag).show?).to be true
    end

    it 'permits a standard user to see a tag used in a project they can access' do
      expect(described_class.new(standard_user, accessible_tag).show?).to be true
    end

    it 'denies a standard user a tag not used in any accessible project' do
      # owned_tag has no taggings → not visible via the project-scoped tag set
      expect(described_class.new(standard_user, owned_tag).show?).to be false
    end

    it 'denies a user from another organisation' do
      expect(described_class.new(other_org_user, accessible_tag).show?).to be false
    end
  end

  # ── create? ─────────────────────────────────────────────────────────

  describe '#create?' do
    it 'permits any authenticated user' do
      expect(described_class.new(standard_user, Tag.new).create?).to be true
      expect(described_class.new(admin_user, Tag.new).create?).to be true
    end
  end

  describe '#new?' do
    it 'delegates to create?' do
      policy = described_class.new(standard_user, Tag.new)
      expect(policy.new?).to eq(policy.create?)
    end
  end

  # ── update? ─────────────────────────────────────────────────────────

  describe '#update?' do
    context 'when user is the tag owner' do
      subject { described_class.new(standard_user, owned_tag) }

      it { is_expected.to permit_action(:update) }
    end

    context 'when user is account admin but not owner' do
      subject { described_class.new(admin_user, owned_tag) }

      it { is_expected.to permit_action(:update) }
    end

    context 'when user is neither owner nor admin' do
      subject { described_class.new(standard_user, other_users_tag) }

      it { is_expected.not_to permit_action(:update) }
    end

    context 'when tag has no owner (user_id nil)' do
      it 'permits for admin' do
        expect(described_class.new(admin_user, unowned_tag).update?).to be true
      end

      it 'denies for standard user' do
        expect(described_class.new(standard_user, unowned_tag).update?).to be false
      end
    end
  end

  # ── destroy? ────────────────────────────────────────────────────────

  describe '#destroy?' do
    context 'when user is the tag owner' do
      subject { described_class.new(standard_user, owned_tag) }

      it { is_expected.to permit_action(:destroy) }
    end

    context 'when user is account admin but not owner' do
      subject { described_class.new(admin_user, owned_tag) }

      it { is_expected.to permit_action(:destroy) }
    end

    context 'when user is neither owner nor admin' do
      subject { described_class.new(standard_user, other_users_tag) }

      it { is_expected.not_to permit_action(:destroy) }
    end

    context 'when tag has no owner (user_id nil)' do
      it 'permits for admin' do
        expect(described_class.new(admin_user, unowned_tag).destroy?).to be true
      end

      it 'denies for standard user' do
        expect(described_class.new(standard_user, unowned_tag).destroy?).to be false
      end
    end
  end

  # ── edit? Delegation ────────────────────────────────────────────────

  describe '#edit?' do
    it 'delegates to update?' do
      policy = described_class.new(standard_user, owned_tag)
      expect(policy.edit?).to eq(policy.update?)
    end

    it 'denied for non-owner same as update?' do
      policy = described_class.new(standard_user, other_users_tag)
      expect(policy.edit?).to eq(policy.update?)
      expect(policy.edit?).to be false
    end
  end

  # ── Cross-org ───────────────────────────────────────────────────────

  describe 'cross-organisation access' do
    it 'denies update for user of a different organisation' do
      expect(described_class.new(other_org_user, owned_tag).update?).to be_falsey
    end

    it 'denies destroy for user of a different organisation' do
      expect(described_class.new(other_org_user, owned_tag).destroy?).to be_falsey
    end
  end

  # ── Scope ───────────────────────────────────────────────────────────

  describe TagPolicy::Scope do
    let(:accessible_project) { create(:project, organisation: organisation) }
    let(:foreign_project) { create(:project, organisation: organisation) }

    let!(:accessible_tag) do
      tag = create(:tag, organisation: organisation)
      create(:tagging, tag: tag, taggable: create(:ticket, project: accessible_project, organisation: organisation))
      tag
    end

    let!(:foreign_tag) do
      tag = create(:tag, organisation: organisation)
      create(:tagging, tag: tag, taggable: create(:ticket, project: foreign_project, organisation: organisation))
      tag
    end

    before do
      create(:project_permission, user: standard_user, project: accessible_project, tickets_access: 'read_only')
    end

    it 'returns all tags for an org admin' do
      result = described_class.new(admin_user, Tag).resolve
      expect(result).to include(accessible_tag, foreign_tag)
    end

    it 'returns only tags used in accessible projects for a standard user' do
      result = described_class.new(standard_user, Tag).resolve
      expect(result).to include(accessible_tag)
      expect(result).not_to include(foreign_tag)
    end

    it 'returns no tags for a user without access to any project' do
      result = described_class.new(other_org_user, Tag).resolve
      expect(result).not_to include(accessible_tag, foreign_tag)
    end
  end
end
