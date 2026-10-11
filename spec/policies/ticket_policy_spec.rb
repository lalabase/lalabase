# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TicketPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation, creator: admin_user) }

  # Roles
  let(:admin_role) { create(:role, title: 'account_admin', organisation: organisation) }
  let(:standard_role) { create(:role, title: 'Standard User', organisation: organisation, is_default: true) }

  let(:tickets_reader_role) do
    role = create(:role, title: 'Tickets Reader', organisation: organisation)
    create(:permission, role: role, category: 'projects', action: 'read_access_tickets_all_projects', allowed: true)
    role
  end

  let(:tickets_writer_role) do
    role = create(:role, title: 'Tickets Writer', organisation: organisation)
    create(:permission, role: role, category: 'projects', action: 'write_access_tickets_all_projects', allowed: true)
    role
  end

  let(:ticket_deleter_role) do
    role = create(:role, title: 'Ticket Deleter', organisation: organisation)
    create(:permission, role: role, category: 'tickets', action: 'delete_tickets', allowed: true)
    role
  end

  let(:ticket_mover_role) do
    role = create(:role, title: 'Ticket Mover', organisation: organisation)
    create(:permission, role: role, category: 'tickets', action: 'move_tickets', allowed: true)
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
    create(:membership, user: user, organisation: organisation, role: tickets_reader_role, active: true)
    user
  end

  let(:writer_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: tickets_writer_role, active: true)
    user
  end

  let(:deleter_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: ticket_deleter_role, active: true)
    user
  end

  let(:mover_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: ticket_mover_role, active: true)
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
    create(:membership, user: user, organisation: organisation, role: tickets_reader_role, active: false)
    user
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # ── Nil user ────────────────────────────────────────────────────────

  describe 'without a logged-in user' do
    it 'raises Pundit::NotAuthorizedError' do
      expect { described_class.new(nil, ticket) }.to raise_error(Pundit::NotAuthorizedError)
    end
  end

  # ── Admin ────────────────────────────────────────────────────────────

  describe 'for admin users' do
    subject { described_class.new(admin_user, ticket) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:show) }
    it { is_expected.to permit_action(:create) }
    it { is_expected.to permit_action(:new) }
    it { is_expected.to permit_action(:update) }
    it { is_expected.to permit_action(:edit) }
    it { is_expected.to permit_action(:destroy) }
    it { is_expected.to permit_action(:move) }
    it { is_expected.to permit_action(:select) }
  end

  # ── Standard user (no permissions) ──────────────────────────────────

  describe 'for standard users without permissions' do
    subject { described_class.new(standard_user, ticket) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.not_to permit_action(:show) }
    it { is_expected.not_to permit_action(:create) }
    it { is_expected.not_to permit_action(:update) }
    it { is_expected.not_to permit_action(:destroy) }
    it { is_expected.not_to permit_action(:move) }
    it { is_expected.not_to permit_action(:select) }
  end

  # ── Reader (read-only) ──────────────────────────────────────────────

  describe 'for users with tickets read permission' do
    subject { described_class.new(reader_user, ticket) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:show) }
    it { is_expected.to permit_action(:select) }
    it { is_expected.not_to permit_action(:create) }
    it { is_expected.not_to permit_action(:update) }
    it { is_expected.not_to permit_action(:destroy) }
    it { is_expected.not_to permit_action(:move) }
  end

  # ── Writer (read + write) ───────────────────────────────────────────

  describe 'for users with tickets write permission' do
    subject { described_class.new(writer_user, ticket) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:show) }
    it { is_expected.to permit_action(:create) }
    it { is_expected.to permit_action(:update) }
    it { is_expected.to permit_action(:select) }
    it { is_expected.not_to permit_action(:destroy) }
    it { is_expected.not_to permit_action(:move) }
  end

  # ── destroy? — own permission category ──────────────────────────────

  describe '#destroy?' do
    it 'permits for admin' do
      expect(described_class.new(admin_user, ticket).destroy?).to be true
    end

    it 'permits for user with delete_tickets permission' do
      expect(described_class.new(deleter_user, ticket).destroy?).to be true
    end

    it 'denies for writer (write does not imply delete)' do
      expect(described_class.new(writer_user, ticket).destroy?).to be false
    end

    it 'denies for reader' do
      expect(described_class.new(reader_user, ticket).destroy?).to be false
    end

    it 'denies for standard user' do
      expect(described_class.new(standard_user, ticket).destroy?).to be false
    end
  end

  # ── move? — own permission category ─────────────────────────────────

  describe '#move?' do
    it 'permits for admin' do
      expect(described_class.new(admin_user, ticket).move?).to be true
    end

    it 'permits for user with move_tickets permission' do
      expect(described_class.new(mover_user, ticket).move?).to be true
    end

    it 'denies for writer (write does not imply move)' do
      expect(described_class.new(writer_user, ticket).move?).to be false
    end

    it 'denies for reader' do
      expect(described_class.new(reader_user, ticket).move?).to be false
    end

    it 'denies for standard user' do
      expect(described_class.new(standard_user, ticket).move?).to be false
    end
  end

  # ── select? delegates to show? ──────────────────────────────────────

  describe '#select?' do
    it 'matches show? for every user type' do
      [admin_user, standard_user, reader_user, writer_user].each do |u|
        policy = described_class.new(u, ticket)
        expect(policy.select?).to eq(policy.show?), "Mismatch for #{u.email}"
      end
    end
  end

  # ── index? is always true ───────────────────────────────────────────

  describe '#index?' do
    it 'permits index for any authenticated user regardless of permissions' do
      expect(described_class.new(standard_user, ticket).index?).to be true
      expect(described_class.new(other_org_user, ticket).index?).to be true
    end
  end

  # ── ProjectPermission overrides ─────────────────────────────────────

  describe 'per-project ProjectPermission overrides' do
    context 'when ProjectPermission grants read_only despite no role permission' do
      before do
        create(:project_permission, user: standard_user, project: project,
                                    tickets_access: 'read_only')
      end

      subject { described_class.new(standard_user, ticket) }

      it { is_expected.to permit_action(:show) }
      it { is_expected.to permit_action(:select) }
      it { is_expected.not_to permit_action(:create) }
      it { is_expected.not_to permit_action(:update) }
    end

    context 'when ProjectPermission grants read_write despite no role permission' do
      before do
        create(:project_permission, user: standard_user, project: project,
                                    tickets_access: 'read_write')
      end

      subject { described_class.new(standard_user, ticket) }

      it { is_expected.to permit_action(:show) }
      it { is_expected.to permit_action(:create) }
      it { is_expected.to permit_action(:update) }
      it { is_expected.to permit_action(:select) }
    end

    context 'when ProjectPermission denies access despite role granting it' do
      before do
        create(:project_permission, user: writer_user, project: project,
                                    tickets_access: 'no_access')
      end

      subject { described_class.new(writer_user, ticket) }

      it 'ProjectPermission no_access overrides global role permission' do
        is_expected.not_to permit_action(:show)
        is_expected.not_to permit_action(:create)
        is_expected.not_to permit_action(:update)
        is_expected.not_to permit_action(:select)
      end
    end
  end

  # ── Cross-tenant / membership edge cases ────────────────────────────

  describe 'cross-tenant and membership edge cases' do
    context 'when user belongs to a different organisation' do
      subject { described_class.new(other_org_user, ticket) }

      it { is_expected.to permit_action(:index) }
      it { is_expected.not_to permit_action(:show) }
      it { is_expected.not_to permit_action(:create) }
      it { is_expected.not_to permit_action(:update) }
      it { is_expected.not_to permit_action(:destroy) }
      it { is_expected.not_to permit_action(:move) }
    end

    context 'when user has inactive membership' do
      subject { described_class.new(inactive_user, ticket) }

      it { is_expected.to permit_action(:index) }
      it { is_expected.not_to permit_action(:show) }
      it { is_expected.not_to permit_action(:create) }
      it { is_expected.not_to permit_action(:update) }
      it { is_expected.not_to permit_action(:destroy) }
      it { is_expected.not_to permit_action(:move) }
    end
  end

  # ── Scope ───────────────────────────────────────────────────────────

  describe TicketPolicy::Scope do
    let(:project_b) { create(:project, organisation: organisation) }
    let!(:ticket_in_project) { create(:ticket, project: project, organisation: organisation, creator: admin_user) }
    let!(:ticket_in_project_b) { create(:ticket, project: project_b, organisation: organisation, creator: admin_user) }

    context 'for admin users' do
      it 'returns all tickets' do
        result = described_class.new(admin_user, Ticket).resolve
        expect(result).to include(ticket_in_project, ticket_in_project_b)
      end
    end

    context 'for users with global tickets read permission' do
      it 'returns tickets from all accessible projects' do
        result = described_class.new(reader_user, Ticket).resolve
        expect(result).to include(ticket_in_project, ticket_in_project_b)
      end
    end

    context 'for standard users without permissions' do
      it 'returns no tickets' do
        result = described_class.new(standard_user, Ticket).resolve
        expect(result).not_to include(ticket_in_project, ticket_in_project_b)
      end
    end

    context 'for users with per-project access to one project only' do
      before do
        create(:project_permission, user: standard_user, project: project,
                                    tickets_access: 'read_only')
      end

      it 'returns only tickets from the permitted project' do
        result = described_class.new(standard_user, Ticket).resolve
        expect(result).to include(ticket_in_project)
        expect(result).not_to include(ticket_in_project_b)
      end
    end

    context 'when ProjectPermission denies access despite role granting it' do
      before do
        create(:project_permission, user: reader_user, project: project,
                                    tickets_access: 'no_access')
      end

      it 'excludes tickets from the denied project' do
        result = described_class.new(reader_user, Ticket).resolve
        expect(result).not_to include(ticket_in_project)
        expect(result).to include(ticket_in_project_b)
      end
    end
  end
end
