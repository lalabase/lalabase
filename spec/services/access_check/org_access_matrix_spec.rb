# frozen_string_literal: true

require 'rails_helper'

# AccessCheck::OrgAccessMatrix aggregates the per-project precedence engine into an org-wide
# grid. These specs pin the behaviour that a raw "who is in the team" query could NOT give:
#
#   * the condensed cell (level / source / blocked / per_area) for each provenance
#   * decision B: the matrix shows the TRUE effective access (explicit read_only lifted to
#     read_write by a role's global write), not the raw explicit grant
#   * "explicit no_access" is a deliberate block (blocked), distinct from "never" (:none)
#   * rows are active members only (an active membership is NOT enough — the user must be
#     active and not soft-deleted; Codex C3), columns are active projects only
#   * cross-tenant isolation
#   * the N+1 guard: query count is independent of the member count U
RSpec.describe AccessCheck::OrgAccessMatrix, type: :service do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  let(:admin_role)  { create(:admin_role, organisation: organisation) }
  let(:member_role) { create(:role, organisation: organisation, title: 'member') }
  let(:current_user) { create(:user) } # the viewer; only used for is_self

  let(:project) { create(:project, organisation: organisation, name: 'Alpha') }

  def member_in(role)
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role)
    user
  end

  # A role carrying a single global project right, plus a member holding it.
  def member_with_global(kind, area:)
    role = create(:role, organisation: organisation, title: "#{kind}_#{area}_#{SecureRandom.hex(3)}")
    create(:"project_#{kind}_permission", role: role, area: area.to_s)
    member_in(role)
  end

  def matrix
    described_class.new(organisation: organisation, current_user: current_user)
  end

  def cell_for(user, proj = project)
    matrix.cell(user, proj)
  end

  describe 'condensed cell semantics' do
    it 'shows account_admin as read_write in every area, source :admin, not blocked' do
      cell = cell_for(member_in(admin_role))

      expect(cell.source).to eq(:admin)
      expect(cell.level).to eq('read_write')
      expect(cell.blocked?).to be(false)
      expect(cell.per_area.values.uniq).to eq(['read_write'])
    end

    it 'condenses a direct grant to the highest area level, source :direct' do
      user = member_in(member_role)
      create(:project_permission, user: user, project: project,
                                  tickets_access: 'read_write', notes_access: 'read_only')

      cell = cell_for(user)

      expect(cell.source).to eq(:direct)
      expect(cell.level).to eq('read_write')
      expect(cell.blocked?).to be(false)
      expect(cell.per_area[:tickets]).to eq('read_write')
      expect(cell.per_area[:notes]).to eq('read_only')
      expect(cell.per_area[:chats]).to eq('no_access')
    end

    it 'flags a direct grant with every area no_access as blocked (explicit lock-out)' do
      user = member_in(member_role)
      create(:project_permission, user: user, project: project) # all columns default to no_access

      cell = cell_for(user)

      expect(cell.source).to eq(:direct)
      expect(cell.blocked?).to be(true)
      expect(cell.level).to eq('no_access')
    end

    it 'shows a global role right as source :role with the role level per area' do
      user = member_with_global(:read, area: :tickets)

      cell = cell_for(user)

      expect(cell.source).to eq(:role)
      expect(cell.per_area[:tickets]).to eq('read_only')
      expect(cell.per_area[:notes]).to eq('no_access')
      expect(cell.level).to eq('read_only')
      expect(cell.blocked?).to be(false)
    end

    it 'is source :none (not blocked) for a member with no access at all' do
      cell = cell_for(member_in(member_role))

      expect(cell.source).to eq(:none)
      expect(cell.none?).to be(true)
      expect(cell.blocked?).to be(false) # blocked != none
      expect(cell.level).to eq('no_access')
    end

    it 'exposes all six area levels in per_area' do
      user = member_in(member_role)
      create(:project_permission, user: user, project: project, tickets_access: 'read_only')

      expect(cell_for(user).per_area.keys).to match_array(ProjectPermission.access_areas)
    end
  end

  describe 'decision B: effective-access honesty' do
    it 'lifts an explicit read_only to read_write when the role grants global write' do
      role = create(:role, organisation: organisation, title: 'ticket_writer')
      create(:project_write_permission, role: role, area: 'tickets')
      user = create(:user)
      create(:membership, user: user, organisation: organisation, role: role)
      create(:project_permission, user: user, project: project, tickets_access: 'read_only')

      cell = cell_for(user)

      # Source stays :direct (an explicit grant exists), but the shown level is the true
      # effective one — read_write — NOT the raw explicit read_only the Team page would show.
      expect(cell.source).to eq(:direct)
      expect(cell.per_area[:tickets]).to eq('read_write')
      expect(cell.level).to eq('read_write')
    end

    it 'lets an explicit no_access override a role right (blocked, precedence over role)' do
      role = create(:role, organisation: organisation, title: 'ticket_reader_blocked')
      create(:project_read_permission, role: role, area: 'tickets')
      user = create(:user)
      create(:membership, user: user, organisation: organisation, role: role)
      create(:project_permission, user: user, project: project, tickets_access: 'no_access')

      cell = cell_for(user)

      expect(cell.source).to eq(:direct)
      expect(cell.per_area[:tickets]).to eq('no_access')
      expect(cell.blocked?).to be(true)
    end
  end

  describe 'rows = active members only (Codex C3)' do
    it 'includes an active member' do
      active = member_in(member_role)
      expect(matrix.users.map(&:id)).to include(active.id)
    end

    it 'excludes a deactivated user even with an active membership' do
      inactive = create(:user, active: false)
      create(:membership, user: inactive, organisation: organisation, role: member_role)

      expect(matrix.users.map(&:id)).not_to include(inactive.id)
    end

    it 'excludes a soft-deleted user even with an active membership' do
      deleted = member_in(member_role)
      deleted.update_columns(deleted_at: Time.current)

      expect(matrix.users.map(&:id)).not_to include(deleted.id)
    end
  end

  describe 'columns = active projects only' do
    it 'includes an active project and excludes an archived one' do
      active = project # force creation of the active (Alpha) column BEFORE the matrix loads
      archived = create(:project, organisation: organisation, name: 'Zeta', archived_at: Time.current)

      ids = matrix.projects.map(&:id)
      expect(ids).to include(active.id)
      expect(ids).not_to include(archived.id)
    end
  end

  describe 'cross-tenant isolation' do
    it 'never surfaces another organisation\'s users or projects' do
      other_org = create(:organisation)
      other_user = nil
      other_project = nil
      ActsAsTenant.with_tenant(other_org) do
        other_project = create(:project, organisation: other_org, name: 'Foreign')
        other_role = create(:role, organisation: other_org, title: 'foreign')
        other_user = create(:user)
        create(:membership, user: other_user, organisation: other_org, role: other_role)
      end

      expect(matrix.users.map(&:id)).not_to include(other_user.id)
      expect(matrix.projects.map(&:id)).not_to include(other_project.id)
    end
  end

  describe 'N+1: query count is independent of the number of users' do
    def count_queries
      count = 0
      sub = ActiveSupport::Notifications.subscribe('sql.active_record') do |_, _, _, _, payload|
        name = payload[:name]
        sql = payload[:sql]
        next if %w[SCHEMA TRANSACTION].include?(name)
        next if sql =~ /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i

        count += 1
      end
      yield
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    def realize(instance)
      instance.users.each { |u| instance.projects.each { |p| instance.cell(u, p) } }
    end

    # A role that grants global tickets WRITE — used to make direct grants exercise the
    # decision-B lift (explicit read_only + role write → read_write).
    def writer_role
      @writer_role ||= begin
        role = create(:role, organisation: organisation, title: "writer_#{SecureRandom.hex(3)}")
        create(:project_write_permission, role: role, area: 'tickets')
        role
      end
    end

    def reader_role
      @reader_role ||= begin
        role = create(:role, organisation: organisation, title: "reader_#{SecureRandom.hex(3)}")
        create(:project_read_permission, role: role, area: 'tickets')
        role
      end
    end

    # Grows BOTH provenance paths: a :role member (raw_levels) AND a :direct member whose
    # explicit read_only is lifted by the role's global write — the latter is the ONLY path
    # that hits role_levels_for / ProjectPermission#effective_level, where a per-user query
    # would otherwise hide (the exact U×P anti-pattern the plan forbids). Grow it, and the
    # equality below proves that path is query-free too.
    def add_members(count, project)
      count.times do
        role_member = create(:user)
        create(:membership, user: role_member, organisation: organisation, role: reader_role)

        direct_member = create(:user)
        create(:membership, user: direct_member, organisation: organisation, role: writer_role)
        create(:project_permission, user: direct_member, project: project, tickets_access: 'read_only')
      end
    end

    it 'stays constant as the member set grows — both the :role and :direct paths (independent of U)' do
      # Force lazily-created fixtures BEFORE measuring, so their INSERTs don't land in one
      # block and skew the comparison. What's measured is purely the matrix realization.
      current_user
      alpha = project # the first (Alpha) column
      create(:project, organisation: organisation, name: 'Beta') # => 2 active projects (P=2)

      add_members(2, alpha) # 2 role + 2 direct (lift) members
      q_small = count_queries { realize(described_class.new(organisation: organisation, current_user: current_user)) }

      add_members(4, alpha) # grow both paths
      q_large = count_queries { realize(described_class.new(organisation: organisation, current_user: current_user)) }

      # U-independence: growing the member set adds NO queries.
      expect(q_large).to eq(q_small)
      # Absolute budget: a few constant loads (users + preloads + projects) plus at most 3
      # per project. A regression that adds a per-project or per-cell query breaks this.
      expect(q_small).to be <= 6 + (3 * 2)
    end
  end
end
