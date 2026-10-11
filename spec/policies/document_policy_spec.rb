# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DocumentPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:document) { create(:document, project: project, organisation: organisation, creator: admin_user) }

  # Roles
  let(:admin_role) { create(:role, title: 'account_admin', organisation: organisation) }
  let(:standard_role) { create(:role, title: 'Standard User', organisation: organisation, is_default: true) }

  let(:documents_reader_role) do
    role = create(:role, title: 'Documents Reader', organisation: organisation)
    create(:permission, role: role, category: 'projects', action: 'read_access_documents_all_projects', allowed: true)
    role
  end

  let(:documents_writer_role) do
    role = create(:role, title: 'Documents Writer', organisation: organisation)
    create(:permission, role: role, category: 'projects', action: 'write_access_documents_all_projects', allowed: true)
    role
  end

  # Users
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

  let(:reader_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: documents_reader_role, active: true)
    user
  end

  let(:writer_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: documents_writer_role, active: true)
    user
  end

  let(:other_org_user) do
    other_role = create(:role, title: 'Other Org Role', organisation: other_organisation)
    user = create(:user)
    create(:membership, user: user, organisation: other_organisation, role: other_role, active: true)
    user
  end

  let(:inactive_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: documents_reader_role, active: false)
    user
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # ── Nil user ────────────────────────────────────────────────────────

  describe 'without a logged-in user' do
    it 'raises Pundit::NotAuthorizedError' do
      expect { described_class.new(nil, document) }.to raise_error(Pundit::NotAuthorizedError)
    end
  end

  # ── Admin ────────────────────────────────────────────────────────────

  describe 'for admin users' do
    subject { described_class.new(admin_user, document) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:show) }
    it { is_expected.to permit_action(:create) }
    it { is_expected.to permit_action(:new) }
    it { is_expected.to permit_action(:update) }
    it { is_expected.to permit_action(:edit) }
    it { is_expected.to permit_action(:destroy) }
  end

  # ── Standard user (no permissions) ──────────────────────────────────

  describe 'for standard users without permissions' do
    subject { described_class.new(standard_user, document) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.not_to permit_action(:show) }
    it { is_expected.not_to permit_action(:create) }
    it { is_expected.not_to permit_action(:update) }
    it { is_expected.not_to permit_action(:destroy) }
  end

  # ── Reader (read-only) ──────────────────────────────────────────────

  describe 'for users with documents read permission' do
    subject { described_class.new(reader_user, document) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:show) }
    it { is_expected.not_to permit_action(:create) }
    it { is_expected.not_to permit_action(:update) }
    it { is_expected.not_to permit_action(:destroy) }
  end

  # ── Writer (read + write) ───────────────────────────────────────────

  describe 'for users with documents write permission' do
    subject { described_class.new(writer_user, document) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:show) }
    it { is_expected.to permit_action(:create) }
    it { is_expected.to permit_action(:update) }
    it { is_expected.to permit_action(:destroy) }
  end

  # ── index? is always true ───────────────────────────────────────────

  describe '#index?' do
    it 'permits index for any authenticated user regardless of permissions' do
      expect(described_class.new(standard_user, document).index?).to be true
      expect(described_class.new(reader_user, document).index?).to be true
      expect(described_class.new(other_org_user, document).index?).to be true
    end
  end

  # ── destroy? admin special right ────────────────────────────────────

  describe '#destroy?' do
    it 'permits destroy for admin even without explicit documents write permission' do
      create(:role, title: 'admin_no_docs', organisation: organisation)
      # No documents permission, but account_admin
      admin_role # account_admin title
      expect(described_class.new(admin_user, document).destroy?).to be true
    end

    it 'permits destroy for writer' do
      expect(described_class.new(writer_user, document).destroy?).to be true
    end

    it 'denies destroy for reader (read does not imply delete)' do
      expect(described_class.new(reader_user, document).destroy?).to be false
    end
  end

  # ── ProjectPermission overrides ─────────────────────────────────────

  describe 'per-project ProjectPermission overrides' do
    context 'when ProjectPermission grants read_only despite no role permission' do
      before do
        create(:project_permission, user: standard_user, project: project,
                                    documents_access: 'read_only')
      end

      subject { described_class.new(standard_user, document) }

      it { is_expected.to permit_action(:show) }
      it { is_expected.not_to permit_action(:create) }
      it { is_expected.not_to permit_action(:update) }
      it { is_expected.not_to permit_action(:destroy) }
    end

    context 'when ProjectPermission grants read_write despite no role permission' do
      before do
        create(:project_permission, user: standard_user, project: project,
                                    documents_access: 'read_write')
      end

      subject { described_class.new(standard_user, document) }

      it { is_expected.to permit_action(:show) }
      it { is_expected.to permit_action(:create) }
      it { is_expected.to permit_action(:update) }
      it { is_expected.to permit_action(:destroy) }
    end

    context 'when ProjectPermission denies access despite role granting it' do
      before do
        create(:project_permission, user: writer_user, project: project,
                                    documents_access: 'no_access')
      end

      subject { described_class.new(writer_user, document) }

      it 'ProjectPermission no_access overrides global role permission' do
        is_expected.not_to permit_action(:show)
        is_expected.not_to permit_action(:create)
        is_expected.not_to permit_action(:update)
        is_expected.not_to permit_action(:destroy)
      end
    end
  end

  # ── Cross-tenant / membership edge cases ────────────────────────────

  describe 'cross-tenant and membership edge cases' do
    context 'when user belongs to a different organisation' do
      subject { described_class.new(other_org_user, document) }

      it { is_expected.to permit_action(:index) }
      it { is_expected.not_to permit_action(:show) }
      it { is_expected.not_to permit_action(:create) }
      it { is_expected.not_to permit_action(:update) }
      it { is_expected.not_to permit_action(:destroy) }
    end

    context 'when user has inactive membership' do
      subject { described_class.new(inactive_user, document) }

      it { is_expected.to permit_action(:index) }
      it { is_expected.not_to permit_action(:show) }
      it { is_expected.not_to permit_action(:create) }
      it { is_expected.not_to permit_action(:update) }
      it { is_expected.not_to permit_action(:destroy) }
    end
  end

  # ── Scope ───────────────────────────────────────────────────────────

  describe DocumentPolicy::Scope do
    let(:project_b) { create(:project, organisation: organisation) }
    let!(:doc_in_project) { create(:document, project: project, organisation: organisation, creator: admin_user) }
    let!(:doc_in_project_b) { create(:document, project: project_b, organisation: organisation, creator: admin_user) }

    context 'for admin users' do
      it 'returns all documents' do
        result = described_class.new(admin_user, Document).resolve
        expect(result).to include(doc_in_project, doc_in_project_b)
      end
    end

    context 'for users with global documents read permission' do
      it 'returns documents from all accessible projects' do
        result = described_class.new(reader_user, Document).resolve
        expect(result).to include(doc_in_project, doc_in_project_b)
      end
    end

    context 'for standard users without permissions' do
      it 'returns no documents' do
        result = described_class.new(standard_user, Document).resolve
        expect(result).not_to include(doc_in_project, doc_in_project_b)
      end
    end

    context 'for users with per-project access to one project only' do
      before do
        create(:project_permission, user: standard_user, project: project,
                                    documents_access: 'read_only')
      end

      it 'returns only documents from the permitted project' do
        result = described_class.new(standard_user, Document).resolve
        expect(result).to include(doc_in_project)
        expect(result).not_to include(doc_in_project_b)
      end
    end

    context 'when ProjectPermission denies access despite role granting it' do
      before do
        create(:project_permission, user: reader_user, project: project,
                                    documents_access: 'no_access')
      end

      it 'excludes documents from the denied project' do
        result = described_class.new(reader_user, Document).resolve
        expect(result).not_to include(doc_in_project)
        expect(result).to include(doc_in_project_b)
      end
    end
  end
end
