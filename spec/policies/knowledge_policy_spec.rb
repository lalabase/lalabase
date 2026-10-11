# frozen_string_literal: true

require 'rails_helper'

RSpec.describe KnowledgePolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  # Roles
  let(:admin_role) do
    create(:role, title: 'account_admin', organisation: organisation)
  end

  let(:standard_role) do
    create(:role, title: 'Standard User', organisation: organisation, is_default: true)
  end

  let(:notes_reader_role) do
    role = create(:role, title: 'Notes Reader', organisation: organisation)
    create(:permission, role: role, category: 'projects', action: 'read_access_notes_all_projects', allowed: true)
    role
  end

  let(:documents_reader_role) do
    role = create(:role, title: 'Documents Reader', organisation: organisation)
    create(:permission, role: role, category: 'projects', action: 'read_access_documents_all_projects', allowed: true)
    role
  end

  let(:notes_writer_role) do
    role = create(:role, title: 'Notes Writer', organisation: organisation)
    create(:permission, role: role, category: 'projects', action: 'write_access_notes_all_projects', allowed: true)
    role
  end

  let(:documents_writer_role) do
    role = create(:role, title: 'Documents Writer', organisation: organisation)
    create(:permission, role: role, category: 'projects', action: 'write_access_documents_all_projects', allowed: true)
    role
  end

  let(:meetings_reader_role) do
    role = create(:role, title: 'Meetings Reader', organisation: organisation)
    create(:permission, role: role, category: 'projects', action: 'read_access_meetings_all_projects', allowed: true)
    role
  end

  let(:notes_and_documents_reader_role) do
    role = create(:role, title: 'Notes+Docs Reader', organisation: organisation)
    create(:permission, role: role, category: 'projects', action: 'read_access_notes_all_projects', allowed: true)
    create(:permission, role: role, category: 'projects', action: 'read_access_documents_all_projects', allowed: true)
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

  let(:notes_reader_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: notes_reader_role, active: true)
    user
  end

  let(:documents_reader_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: documents_reader_role, active: true)
    user
  end

  let(:notes_writer_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: notes_writer_role, active: true)
    user
  end

  let(:documents_writer_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: documents_writer_role, active: true)
    user
  end

  let(:meetings_reader_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: meetings_reader_role, active: true)
    user
  end

  let(:inactive_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: notes_and_documents_reader_role, active: false)
    user
  end

  let(:other_org_user) do
    other_role = create(:role, title: 'Other Org Role', organisation: other_organisation)
    user = create(:user)
    create(:membership, user: user, organisation: other_organisation, role: other_role, active: true)
    user
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # ── Edge Case: nil user ──────────────────────────────────────────────

  describe 'without a logged-in user' do
    it 'raises Pundit::NotAuthorizedError' do
      expect { described_class.new(nil, project) }.to raise_error(Pundit::NotAuthorizedError)
    end
  end

  # ── Admin ────────────────────────────────────────────────────────────

  describe 'for admin users' do
    subject { described_class.new(admin_user, project) }

    it { is_expected.to permit_action(:index) }
  end

  # ── Standard user (no permissions) ──────────────────────────────────

  describe 'for standard users without any permissions' do
    subject { described_class.new(standard_user, project) }

    it { is_expected.not_to permit_action(:index) }
  end

  # ── Inherited ApplicationPolicy defaults ────────────────────────────

  describe 'actions inherited from ApplicationPolicy' do
    subject { described_class.new(admin_user, project) }

    it { is_expected.not_to permit_action(:show) }
    it { is_expected.not_to permit_action(:create) }
    it { is_expected.not_to permit_action(:new) }
    it { is_expected.not_to permit_action(:update) }
    it { is_expected.not_to permit_action(:edit) }
    it { is_expected.not_to permit_action(:destroy) }
  end

  # ── Role-based access (global permissions) ──────────────────────────

  describe 'role-based access via global permissions' do
    context 'with read_access_notes_all_projects only' do
      subject { described_class.new(notes_reader_user, project) }

      it { is_expected.to permit_action(:index) }
    end

    context 'with read_access_documents_all_projects only' do
      subject { described_class.new(documents_reader_user, project) }

      it { is_expected.to permit_action(:index) }
    end

    context 'with write_access_notes_all_projects (implies read)' do
      subject { described_class.new(notes_writer_user, project) }

      it { is_expected.to permit_action(:index) }
    end

    context 'with write_access_documents_all_projects (implies read)' do
      subject { described_class.new(documents_writer_user, project) }

      it { is_expected.to permit_action(:index) }
    end

    context 'with read_access_meetings_all_projects only' do
      subject { described_class.new(meetings_reader_user, project) }

      it { is_expected.not_to permit_action(:index) }
    end
  end

  # ── ProjectPermission overrides (per-project) ──────────────────────

  describe 'per-project ProjectPermission overrides' do
    context 'when notes=read_only, documents=no_access' do
      before do
        create(:project_permission, user: standard_user, project: project,
                                    notes_access: 'read_only', documents_access: 'no_access')
      end

      subject { described_class.new(standard_user, project) }

      it { is_expected.to permit_action(:index) }
    end

    context 'when notes=no_access, documents=read_only' do
      before do
        create(:project_permission, user: standard_user, project: project,
                                    notes_access: 'no_access', documents_access: 'read_only')
      end

      subject { described_class.new(standard_user, project) }

      it { is_expected.to permit_action(:index) }
    end

    context 'when notes=read_write, documents=no_access' do
      before do
        create(:project_permission, user: standard_user, project: project,
                                    notes_access: 'read_write', documents_access: 'no_access')
      end

      subject { described_class.new(standard_user, project) }

      it { is_expected.to permit_action(:index) }
    end

    context 'when both notes and documents are no_access' do
      before do
        create(:project_permission, user: standard_user, project: project,
                                    notes_access: 'no_access', documents_access: 'no_access')
      end

      subject { described_class.new(standard_user, project) }

      it { is_expected.not_to permit_action(:index) }
    end

    context 'when only meetings=read_only is granted' do
      before do
        create(:project_permission, user: standard_user, project: project,
                                    notes_access: 'no_access', documents_access: 'no_access', meetings_access: 'read_only')
      end

      subject { described_class.new(standard_user, project) }

      it { is_expected.not_to permit_action(:index) }
    end

    context 'when ProjectPermission denies access despite role granting it' do
      before do
        create(:project_permission, user: notes_reader_user, project: project,
                                    notes_access: 'no_access', documents_access: 'no_access')
      end

      subject { described_class.new(notes_reader_user, project) }

      it 'ProjectPermission no_access overrides global role permission' do
        is_expected.not_to permit_action(:index)
      end
    end
  end

  # ── Cross-tenant / membership edge cases ────────────────────────────

  describe 'cross-tenant and membership edge cases' do
    context 'when user belongs to a different organisation' do
      subject { described_class.new(other_org_user, project) }

      it { is_expected.not_to permit_action(:index) }
    end

    context 'when user has inactive membership' do
      subject { described_class.new(inactive_user, project) }

      it { is_expected.not_to permit_action(:index) }
    end
  end
end
