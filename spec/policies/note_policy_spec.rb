# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NotePolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:note) { create(:note, project: project, organisation: organisation, creator: admin_user) }

  # Roles
  let(:admin_role) { create(:role, title: 'account_admin', organisation: organisation) }
  let(:standard_role) { create(:role, title: 'Standard User', organisation: organisation, is_default: true) }

  let(:notes_reader_role) do
    role = create(:role, title: 'Notes Reader', organisation: organisation)
    create(:permission, role: role, category: 'projects', action: 'read_access_notes_all_projects', allowed: true)
    role
  end

  let(:notes_writer_role) do
    role = create(:role, title: 'Notes Writer', organisation: organisation)
    create(:permission, role: role, category: 'projects', action: 'write_access_notes_all_projects', allowed: true)
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
    create(:membership, user: user, organisation: organisation, role: notes_reader_role, active: true)
    user
  end

  let(:writer_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: notes_writer_role, active: true)
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
    create(:membership, user: user, organisation: organisation, role: notes_reader_role, active: false)
    user
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # ── Nil user ────────────────────────────────────────────────────────

  describe 'without a logged-in user' do
    it 'raises Pundit::NotAuthorizedError' do
      expect { described_class.new(nil, note) }.to raise_error(Pundit::NotAuthorizedError)
    end
  end

  # ── Admin ────────────────────────────────────────────────────────────

  describe 'for admin users' do
    subject { described_class.new(admin_user, note) }

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
    subject { described_class.new(standard_user, note) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.not_to permit_action(:show) }
    it { is_expected.not_to permit_action(:create) }
    it { is_expected.not_to permit_action(:update) }
    it { is_expected.not_to permit_action(:destroy) }
  end

  # ── Reader (read-only) ──────────────────────────────────────────────

  describe 'for users with notes read permission' do
    subject { described_class.new(reader_user, note) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:show) }
    it { is_expected.not_to permit_action(:create) }
    it { is_expected.not_to permit_action(:update) }
    it { is_expected.not_to permit_action(:destroy) }
  end

  # ── Writer (read + write) ───────────────────────────────────────────

  describe 'for users with notes write permission' do
    subject { described_class.new(writer_user, note) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:show) }
    it { is_expected.to permit_action(:create) }
    it { is_expected.to permit_action(:update) }
    it { is_expected.to permit_action(:destroy) }
  end

  # ── index? is always true ───────────────────────────────────────────

  describe '#index?' do
    it 'permits index for any authenticated user regardless of permissions' do
      expect(described_class.new(standard_user, note).index?).to be true
      expect(described_class.new(other_org_user, note).index?).to be true
    end
  end

  # ── destroy? admin special right ────────────────────────────────────

  describe '#destroy?' do
    it 'permits destroy for admin' do
      expect(described_class.new(admin_user, note).destroy?).to be true
    end

    it 'permits destroy for writer' do
      expect(described_class.new(writer_user, note).destroy?).to be true
    end

    it 'denies destroy for reader (read does not imply delete)' do
      expect(described_class.new(reader_user, note).destroy?).to be false
    end

    it 'denies destroy for standard user' do
      expect(described_class.new(standard_user, note).destroy?).to be false
    end
  end

  # ── ProjectPermission overrides ─────────────────────────────────────

  describe 'per-project ProjectPermission overrides' do
    context 'when ProjectPermission grants read_only despite no role permission' do
      before do
        create(:project_permission, user: standard_user, project: project,
                                    notes_access: 'read_only')
      end

      subject { described_class.new(standard_user, note) }

      it { is_expected.to permit_action(:show) }
      it { is_expected.not_to permit_action(:create) }
      it { is_expected.not_to permit_action(:update) }
      it { is_expected.not_to permit_action(:destroy) }
    end

    context 'when ProjectPermission grants read_write despite no role permission' do
      before do
        create(:project_permission, user: standard_user, project: project,
                                    notes_access: 'read_write')
      end

      subject { described_class.new(standard_user, note) }

      it { is_expected.to permit_action(:show) }
      it { is_expected.to permit_action(:create) }
      it { is_expected.to permit_action(:update) }
      it { is_expected.to permit_action(:destroy) }
    end

    context 'when ProjectPermission denies access despite role granting it' do
      before do
        create(:project_permission, user: writer_user, project: project,
                                    notes_access: 'no_access')
      end

      subject { described_class.new(writer_user, note) }

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
      subject { described_class.new(other_org_user, note) }

      it { is_expected.to permit_action(:index) }
      it { is_expected.not_to permit_action(:show) }
      it { is_expected.not_to permit_action(:create) }
      it { is_expected.not_to permit_action(:update) }
      it { is_expected.not_to permit_action(:destroy) }
    end

    context 'when user has inactive membership' do
      subject { described_class.new(inactive_user, note) }

      it { is_expected.to permit_action(:index) }
      it { is_expected.not_to permit_action(:show) }
      it { is_expected.not_to permit_action(:create) }
      it { is_expected.not_to permit_action(:update) }
      it { is_expected.not_to permit_action(:destroy) }
    end
  end

  # ── Scope ───────────────────────────────────────────────────────────

  describe NotePolicy::Scope do
    let(:project_b) { create(:project, organisation: organisation) }
    let!(:note_in_project) { create(:note, project: project, organisation: organisation, creator: admin_user) }
    let!(:note_in_project_b) { create(:note, project: project_b, organisation: organisation, creator: admin_user) }

    context 'for admin users' do
      it 'returns all notes' do
        result = described_class.new(admin_user, Note).resolve
        expect(result).to include(note_in_project, note_in_project_b)
      end
    end

    context 'for users with global notes read permission' do
      it 'returns notes from all accessible projects' do
        result = described_class.new(reader_user, Note).resolve
        expect(result).to include(note_in_project, note_in_project_b)
      end
    end

    context 'for standard users without permissions' do
      it 'returns no notes' do
        result = described_class.new(standard_user, Note).resolve
        expect(result).not_to include(note_in_project, note_in_project_b)
      end
    end

    context 'for users with per-project access to one project only' do
      before do
        create(:project_permission, user: standard_user, project: project,
                                    notes_access: 'read_only')
      end

      it 'returns only notes from the permitted project' do
        result = described_class.new(standard_user, Note).resolve
        expect(result).to include(note_in_project)
        expect(result).not_to include(note_in_project_b)
      end
    end

    context 'when ProjectPermission denies access despite role granting it' do
      before do
        create(:project_permission, user: reader_user, project: project,
                                    notes_access: 'no_access')
      end

      it 'excludes notes from the denied project' do
        result = described_class.new(reader_user, Note).resolve
        expect(result).not_to include(note_in_project)
        expect(result).to include(note_in_project_b)
      end
    end
  end
end
