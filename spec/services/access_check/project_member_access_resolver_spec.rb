# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccessCheck::ProjectMemberAccessResolver, type: :service do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:project) { create(:project, organisation: organisation) }
  let(:viewer) { create(:user) } # the current_user doing the viewing

  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:member_role) { create(:role, organisation: organisation, title: 'member') }
  let(:tickets_reader_role) do
    role = create(:role, organisation: organisation, title: 'tickets_reader')
    create(:project_read_permission, role: role, area: 'tickets')
    role
  end

  def member_in(role)
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role)
    user
  end

  def resolve(user)
    described_class.new(project: project, current_user: viewer).for_user(user)
  end

  describe '#for_user provenance + effective levels' do
    it 'treats account_admin as full write everywhere, inherited, source :admin' do
      result = resolve(member_in(admin_role))

      expect(result.source).to eq(:admin)
      expect(result.cells.values.map(&:level).uniq).to eq(['read_write'])
      expect(result.cells.values).to all(have_attributes(inherited: true))
      expect(result.time.status).to eq(:full)
    end

    it 'reads an explicit ProjectPermission as source :direct, not inherited' do
      user = member_in(member_role)
      create(:project_permission, user: user, project: project,
                                  tickets_access: 'read_write', notes_access: 'read_only')

      result = resolve(user)

      expect(result.source).to eq(:direct)
      expect(result.editable?).to be(true)
      expect(result.cells[:tickets]).to have_attributes(level: 'read_write', inherited: false)
      expect(result.cells[:notes]).to have_attributes(level: 'read_only', inherited: false)
      expect(result.cells[:chats].level).to eq('no_access')
    end

    it 'derives a global role right as source :role, inherited per area' do
      result = resolve(member_in(tickets_reader_role))

      expect(result.source).to eq(:role)
      expect(result.cells[:tickets]).to have_attributes(level: 'read_only', inherited: true)
      expect(result.cells[:notes].level).to eq('no_access')
    end

    it 'lets an explicit grant OVERRIDE a role right (the "(modifiziert)" path)' do
      user = member_in(tickets_reader_role) # role grants read tickets...
      create(:project_permission, user: user, project: project, tickets_access: 'read_write') # ...explicit wins

      result = resolve(user)

      expect(result.source).to eq(:direct)
      expect(result.cells[:tickets]).to have_attributes(level: 'read_write', inherited: false)
    end

    it 'is :none for a member with neither explicit grant nor global role right' do
      result = resolve(member_in(member_role))

      expect(result.source).to eq(:none)
      expect(result.access?).to be(false)
    end

    it 'defaults to no_access when the user has no role in the org' do
      result = resolve(create(:user)) # no membership

      expect(result.source).to eq(:none)
      expect(result.cells.values.map(&:level).uniq).to eq(['no_access'])
    end

    it 'flags the viewer\'s own row via is_self' do
      create(:membership, user: viewer, organisation: organisation, role: member_role)
      create(:project_permission, user: viewer, project: project, tickets_access: 'read_only')

      expect(resolve(viewer).is_self).to be(true)
    end
  end

  # role_override answers the ONE question the remove button depends on: would
  # dropping the explicit row leave this person with access anyway?
  describe '#role_override' do
    it 'is false when no role right stands behind the explicit grant' do
      user = member_in(member_role)
      create(:project_permission, user: user, project: project, tickets_access: 'read_write')

      expect(resolve(user).role_override).to be(false)
    end

    it 'is true when a global role right would take over' do
      user = member_in(tickets_reader_role)
      create(:project_permission, user: user, project: project, tickets_access: 'read_write')

      expect(resolve(user).role_override).to be(true)
    end

    it 'is true for a member who is on the project through the role alone' do
      expect(resolve(member_in(tickets_reader_role)).role_override).to be(true)
    end

    it 'is false for someone with no role right at all' do
      expect(resolve(member_in(member_role)).role_override).to be(false)
    end
  end

  # A grant that gives nothing while a role right waits behind it can only be a
  # deliberate block: the add-member picker never offers someone who already has
  # access, so this shape cannot be a freshly added member.
  describe '#blocked?' do
    it 'is true for an all-no_access grant that overrides a role right' do
      user = member_in(tickets_reader_role)
      create(:project_permission, user: user, project: project)

      expect(resolve(user).blocked?).to be(true)
    end

    it 'is false for an all-no_access grant with no role right behind it' do
      user = member_in(member_role)
      create(:project_permission, user: user, project: project)

      expect(resolve(user).blocked?).to be(false)
    end

    it 'is false as soon as one area grants something again' do
      user = member_in(tickets_reader_role)
      create(:project_permission, user: user, project: project, notes_access: 'read_only')

      expect(resolve(user).blocked?).to be(false)
    end

    it 'is false for a plain role member' do
      expect(resolve(member_in(tickets_reader_role)).blocked?).to be(false)
    end

    it 'keeps the row editable so the block can be turned back into a grant' do
      user = member_in(tickets_reader_role)
      create(:project_permission, user: user, project: project)

      expect(resolve(user).editable?).to be(true)
    end
  end

  describe 'a blocked member and the roster' do
    let(:blocked_user) do
      user = member_in(tickets_reader_role)
      create(:project_permission, user: user, project: project)
      user
    end

    it 'is kept out of ProjectTeamMembers#with_access, which feeds the dashboard TEAM widget' do
      blocked_user
      roster = AccessCheck::ProjectTeamMembers.new(project: project, current_user: viewer).with_access

      expect(roster.map { |m| m.user.id }).not_to include(blocked_user.id)
    end

    it 'still appears on the team management roster, so the block stays visible and reversible' do
      blocked_user
      roster = AccessCheck::ProjectTeamMembers.new(project: project, current_user: viewer).on_roster

      expect(roster.map { |m| m.user.id }).to include(blocked_user.id)
    end
  end

  describe 'time status' do
    it 'is :standard for a fresh (default) time permission' do
      user = member_in(member_role)
      create(:project_permission, user: user, project: project, tickets_access: 'read_only')

      expect(resolve(user).time.status).to eq(:standard)
    end

    it 'is :custom when the time permission deviates from the defaults' do
      user = member_in(member_role)
      create(:project_permission, user: user, project: project, tickets_access: 'read_only')
      create(:time_session_permission, user: user, project: project, can_view_all: true)

      expect(resolve(user).time.status).to eq(:custom)
    end
  end

  describe 'cross-organisation isolation' do
    it 'does NOT inherit account_admin from a different organisation' do
      other_org = create(:organisation)
      admin_elsewhere = create(:user)
      ActsAsTenant.with_tenant(other_org) do
        other_admin_role = create(:admin_role, organisation: other_org)
        create(:membership, user: admin_elsewhere, organisation: other_org, role: other_admin_role)
      end

      # Resolved against THIS org's project, they have no role here -> no access, no admin leak.
      result = resolve(admin_elsewhere)

      expect(result.source).to eq(:none)
      expect(result.cells.values.map(&:level).uniq).to eq(['no_access'])
    end
  end

  describe 'N+1 regression: query count is independent of member count' do
    def count_queries
      count = 0
      sub = ActiveSupport::Notifications.subscribe('sql.active_record') do |_, _, _, _, payload|
        sql = payload[:sql]
        name = payload[:name]
        next if %w[SCHEMA TRANSACTION].include?(name)
        next if sql =~ /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i

        count += 1
      end
      yield
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    # ROLE-BASED members (no explicit grant) are what exercises the role-rights path —
    # exactly where the original N+1 lived. Mirrors the controller preload so
    # role_in_organisation / role.has_permission? read from memory.
    def add_role_members(count)
      count.times do
        user = create(:user)
        create(:membership, user: user, organisation: organisation, role: tickets_reader_role)
      end
    end

    def preloaded_org_users
      organisation.users.includes(memberships: { role: :permissions }).to_a.each do |u|
        u.memberships.each { |m| m.role&.permissions.to_a } # force the nested preload
      end
    end

    it 'resolves a larger member set with no additional per-member queries' do
      add_role_members(2)
      members2 = preloaded_org_users
      resolver2 = described_class.new(project: project, current_user: viewer)
      q2 = count_queries { resolver2.resolve(members2) }

      add_role_members(4) # now 6 role members in the org
      members6 = preloaded_org_users
      resolver6 = described_class.new(project: project, current_user: viewer)
      q6 = count_queries { resolver6.resolve(members6) }

      # resolve() must be query-free given the preload + per-role memo: constant, not linear.
      expect(q6).to eq(q2)
    end
  end
end
