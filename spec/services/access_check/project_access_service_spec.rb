# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccessCheck::ProjectAccessService do
  let(:organisation) { create(:organisation) }
  let!(:project) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project, organisation: organisation)
    end
  end

  # User with default role
  let(:regular_role) do
    ActsAsTenant.with_tenant(organisation) do
      create(:role, organisation: organisation, title: 'regular_user')
    end
  end
  let(:user) { create(:user) }

  # User with admin role
  let(:admin_user) { create(:user) }

  before do
    ActsAsTenant.with_tenant(organisation) do
      # Create memberships
      create(:membership, user: user, organisation: organisation, role: regular_role)
      create(:membership, user: admin_user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    end
  end

  describe '#can?' do
    context 'when user is an admin' do
      subject { described_class.new(admin_user, project) }

      it 'returns true for any action and area' do
        ActsAsTenant.with_tenant(organisation) do
          expect(subject.can?(:read, :chats)).to be true
          expect(subject.can?(:write, :chats)).to be true
          expect(subject.can?(:read, :tickets)).to be true
          expect(subject.can?(:write, :notes)).to be true
        end
      end
    end

    context 'when user has project-specific permissions' do
      subject { described_class.new(user, project) }

      context 'with read_only permission' do
        before do
          ActsAsTenant.with_tenant(organisation) do
            create(:project_permission,
                   user: user,
                   project: project,
                   chats_access: 'read_only')
          end
        end

        it 'allows read for the permitted area' do
          ActsAsTenant.with_tenant(organisation) do
            expect(subject.can?(:read, :chats)).to be true
          end
        end

        it 'denies write for the permitted area' do
          ActsAsTenant.with_tenant(organisation) do
            expect(subject.can?(:write, :chats)).to be false
          end
        end

        it 'denies access to other areas' do
          ActsAsTenant.with_tenant(organisation) do
            expect(subject.can?(:read, :tickets)).to be false
            expect(subject.can?(:write, :tickets)).to be false
          end
        end
      end

      context 'with read_write permission' do
        before do
          ActsAsTenant.with_tenant(organisation) do
            create(:project_permission,
                   user: user,
                   project: project,
                   tickets_access: 'read_write')
          end
        end

        it 'allows both read and write for the permitted area' do
          ActsAsTenant.with_tenant(organisation) do
            expect(subject.can?(:read, :tickets)).to be true
            expect(subject.can?(:write, :tickets)).to be true
          end
        end

        it 'denies access to other areas' do
          ActsAsTenant.with_tenant(organisation) do
            expect(subject.can?(:read, :chats)).to be false
            expect(subject.can?(:write, :chats)).to be false
          end
        end
      end
    end

    context 'with role-based permissions' do
      subject { described_class.new(user, project) }

      context 'with global read permission' do
        before do
          ActsAsTenant.with_tenant(organisation) do
            # Create a permission for the role
            create(:project_read_permission, role: regular_role, area: 'chats')
          end
        end

        it 'allows read for the permitted area' do
          ActsAsTenant.with_tenant(organisation) do
            expect(subject.can?(:read, :chats)).to be true
          end
        end

        it 'denies write for the permitted area' do
          ActsAsTenant.with_tenant(organisation) do
            expect(subject.can?(:write, :chats)).to be false
          end
        end
      end

      context 'with global write permission' do
        before do
          ActsAsTenant.with_tenant(organisation) do
            # Create a write permission for the role
            create(:project_write_permission, role: regular_role, area: 'notes')
          end
        end

        it 'allows both read and write for the permitted area' do
          ActsAsTenant.with_tenant(organisation) do
            expect(subject.can?(:read, :notes)).to be true
            expect(subject.can?(:write, :notes)).to be true
          end
        end
      end
    end

    context 'when local permissions override role permissions' do
      subject { described_class.new(user, project) }

      context 'with no_access local permission and read role permission' do
        before do
          ActsAsTenant.with_tenant(organisation) do
            # Create a global read permission for the role
            create(:project_read_permission, role: regular_role, area: 'notes')

            # But a local no_access permission
            create(:project_permission,
                   user: user,
                   project: project,
                   notes_access: 'no_access')
          end
        end

        it 'denies access because local permission overrides role permission' do
          ActsAsTenant.with_tenant(organisation) do
            expect(subject.can?(:read, :notes)).to be false
          end
        end
      end

      context 'with read_only local permission and no role permission' do
        before do
          ActsAsTenant.with_tenant(organisation) do
            # Local read permission, but no role permission
            create(:project_permission,
                   user: user,
                   project: project,
                   documents_access: 'read_only')
          end
        end

        it 'allows read access based on local permission' do
          ActsAsTenant.with_tenant(organisation) do
            expect(subject.can?(:read, :documents)).to be true
            expect(subject.can?(:write, :documents)).to be false
          end
        end
      end
    end
  end

  describe '#access_level' do
    context 'when user is an admin' do
      subject { described_class.new(admin_user, project) }

      it 'returns read_write for any area' do
        ActsAsTenant.with_tenant(organisation) do
          expect(subject.access_level(:chats)).to eq('read_write')
          expect(subject.access_level(:tickets)).to eq('read_write')
        end
      end
    end

    context 'with project-specific permissions' do
      subject { described_class.new(user, project) }

      before do
        ActsAsTenant.with_tenant(organisation) do
          create(:project_permission,
                 user: user,
                 project: project,
                 chats_access: 'read_only',
                 tickets_access: 'read_write',
                 notes_access: 'no_access')
        end
      end

      it 'returns the correct access level for each area' do
        ActsAsTenant.with_tenant(organisation) do
          expect(subject.access_level(:chats)).to eq('read_only')
          expect(subject.access_level(:tickets)).to eq('read_write')
          expect(subject.access_level(:notes)).to eq('no_access')
          expect(subject.access_level(:documents)).to eq('no_access')
        end
      end
    end

    context 'with role-based permissions' do
      subject { described_class.new(user, project) }

      before do
        ActsAsTenant.with_tenant(organisation) do
          create(:project_read_permission, role: regular_role, area: 'chats')
          create(:project_write_permission, role: regular_role, area: 'notes')
        end
      end

      it 'returns the correct access level based on role permissions' do
        ActsAsTenant.with_tenant(organisation) do
          expect(subject.access_level(:chats)).to eq('read_only')
          expect(subject.access_level(:notes)).to eq('read_write')
        end
      end
    end

    context 'when local permissions override role permissions' do
      subject { described_class.new(user, project) }

      before do
        ActsAsTenant.with_tenant(organisation) do
          # Global read permission via the role
          create(:project_read_permission, role: regular_role, area: 'tickets')

          # But local specific permissions
          create(:project_permission,
                 user: user,
                 project: project,
                 chats_access: 'read_write', # No role permission, but a local permission
                 tickets_access: 'no_access') # Overrides the role permission
        end
      end

      it 'prioritizes local permissions over role permissions' do
        ActsAsTenant.with_tenant(organisation) do
          expect(subject.access_level(:chats)).to eq('read_write')
          expect(subject.access_level(:tickets)).to eq('no_access')
        end
      end
    end
  end

  describe '.can_access_project?' do
    context 'when user is an admin' do
      it 'returns true' do
        ActsAsTenant.with_tenant(organisation) do
          expect(described_class.can_access_project?(admin_user, project)).to be true
        end
      end
    end

    context 'with project-specific permissions' do
      it 'returns true when user has any read access to the project' do
        ActsAsTenant.with_tenant(organisation) do
          create(:project_permission,
                 user: user,
                 project: project,
                 notes_access: 'read_only')
          expect(described_class.can_access_project?(user, project)).to be true
        end
      end

      it 'returns false when user has no permissions for the project' do
        ActsAsTenant.with_tenant(organisation) do
          # All permissions default to no_access
          create(:project_permission, user: user, project: project)
          expect(described_class.can_access_project?(user, project)).to be false
        end
      end
    end

    context 'with role-based permissions' do
      it 'returns true when user has global read access to any area' do
        ActsAsTenant.with_tenant(organisation) do
          create(:project_read_permission, role: regular_role, area: 'chats')
          expect(described_class.can_access_project?(user, project)).to be true
        end
      end

      it 'returns false when user has no global permissions' do
        ActsAsTenant.with_tenant(organisation) do
          # No specific permissions created
          expect(described_class.can_access_project?(user, project)).to be false
        end
      end
    end

    context 'when local permissions override role permissions' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          # Global read access for tickets
          create(:project_read_permission, role: regular_role, area: 'tickets')

          # But local no_access permissions for all areas
          create(:project_permission, user: user, project: project)
        end
      end

      it 'returns false because local permissions override global permissions' do
        ActsAsTenant.with_tenant(organisation) do
          expect(described_class.can_access_project?(user, project)).to be false
        end
      end
    end
  end

  describe '.accessible_projects' do
    # Declare instead of lazily initializing, to ensure they exist
    let!(:project2) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation)
      end
    end
    let!(:project3) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation)
      end
    end

    context 'when user is an admin' do
      it 'returns all projects in the organisation' do
        ActsAsTenant.with_tenant(organisation) do
          result = described_class.accessible_projects(admin_user, organisation).to_a
          expect(result).to include(project, project2, project3)
        end
      end
    end

    context 'with project-specific permissions' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          # Permissions for project1 and project2, but not for project3
          create(:project_permission,
                 user: user,
                 project: project,
                 tickets_access: 'read_only')
          create(:project_permission,
                 user: user,
                 project: project2,
                 notes_access: 'read_write')
        end
      end

      it 'returns only projects the user has permissions for' do
        ActsAsTenant.with_tenant(organisation) do
          result = described_class.accessible_projects(user, organisation).to_a
          expect(result).to include(project, project2)
          expect(result).not_to include(project3)
        end
      end
    end

    context 'with role-based permissions' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          # Ensure that all projects exist

          # Global read access for chats
          create(:project_read_permission, role: regular_role, area: 'chats')

          # Local no_access for project3 (set explicitly)
          # IMPORTANT: All access areas must be set to no_access
          create(:project_permission,
                 user: user,
                 project: project3,
                 chats_access: 'no_access',
                 tickets_access: 'no_access',
                 notes_access: 'no_access',
                 documents_access: 'no_access')

          # TimeSession access is managed via a separate permission system
          # (no TimeSessionPermission created = no access)
        end
      end

      it 'returns all projects except those with explicit no_access' do
        ActsAsTenant.with_tenant(organisation) do
          # Debug information about the role and permissions
          user.role_in_organisation(organisation)

          # Check all global permissions
          ProjectPermission.access_areas.each do |area|
          end

          # Check whether the method for detecting excluded projects works
          described_class.send(:find_explicitly_excluded_project_ids, user, organisation)

          result = described_class.accessible_projects(user, organisation).to_a

          expect(result).to include(project, project2)
          expect(result).not_to include(project3)
        end
      end
    end
  end

  # The other direction of .can_access_project?, for project news ("any area will do").
  # Two versions of one rule drift, so they are held against each other, person by person.
  describe '.users_with_any_access (the inverse of .can_access_project?)' do
    def member(role: regular_role, active: true)
      create(:user).tap do |person|
        create(:membership, user: person, organisation: organisation, role: role, active: active)
      end
    end

    def role_reading(area)
      create(:role, organisation: organisation).tap do |role|
        create(:permission, role: role, category: 'projects', action: "read_access_#{area}_all_projects", allowed: true)
      end
    end

    it 'names exactly the people .can_access_project? lets in' do
      ActsAsTenant.with_tenant(organisation) do
        through_role = member(role: role_reading(:notes))
        direct = member.tap { |person| create(:project_permission, user: person, project: project, documents_access: 'read_only') }
        blocked = member(role: role_reading(:notes)).tap { |person| create(:project_permission, user: person, project: project) }
        empty_row = member.tap { |person| create(:project_permission, user: person, project: project) }
        people = [admin_user, through_role, direct, blocked, empty_row, user]

        listed = described_class.users_with_any_access(project).where(id: people.map(&:id))

        expect(listed).to contain_exactly(admin_user, through_role, direct)
        expect(people.select { |person| described_class.can_access_project?(person, project) })
          .to contain_exactly(*listed)
      end
    end

    it 'finds a reader of each area alone' do
      ActsAsTenant.with_tenant(organisation) do
        readers = ProjectPermission.access_areas.index_with do |area|
          member.tap { |person| create(:project_permission, user: person, project: project, "#{area}_access": 'read_only') }
        end

        expect(described_class.users_with_any_access(project)).to include(*readers.values)
      end
    end

    # Like .users_with_access: the list is who holds a right, and who may act on it is
    # asked of each person. Notifications::FanoutService#with_current_access does.
    it 'still names a deactivated member, whom .can_access_project? refuses' do
      ActsAsTenant.with_tenant(organisation) do
        deactivated = member(active: false)
        create(:project_permission, user: deactivated, project: project, tickets_access: 'read_only')

        expect(described_class.users_with_any_access(project)).to include(deactivated)
        expect(described_class.can_access_project?(deactivated, project)).to be(false)
      end
    end
  end

  # .users_with_access — the inverse query (who can access THIS project). It had
  # no direct coverage here; the existing tests live in project_spec.rb (via
  # Project#users_with_access) and cover admin + global-role + direct-permission
  # INCLUSION. The branch they miss is step 3: a user who qualifies via a GLOBAL
  # role but carries an explicit no_access ProjectPermission for this project must
  # be EXCLUDED — "global access, except explicitly revoked here". Dropping that
  # exclusion is a real authorization leak (the user would still be notified and
  # appear in subscriber lists), so it is pinned from both sides plus per-project.
  describe '.users_with_access (global no_access override — step 3)' do
    let(:global_reader) { create(:user) }
    let(:global_role) do
      ActsAsTenant.with_tenant(organisation) do
        role = create(:role, organisation: organisation)
        create(:permission, role: role, category: 'projects',
                            action: 'read_access_tickets_all_projects', allowed: true)
        role
      end
    end

    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: global_reader, organisation: organisation, role: global_role)
      end
    end

    it 'includes a globally-permitted user when there is no project override' do
      ActsAsTenant.with_tenant(organisation) do
        expect(described_class.users_with_access(project, :read, :tickets)).to include(global_reader)
      end
    end

    it 'excludes a globally-permitted user who has an explicit no_access override here' do
      ActsAsTenant.with_tenant(organisation) do
        create(:project_permission, user: global_reader, project: project, tickets_access: 'no_access')
        expect(described_class.users_with_access(project, :read, :tickets)).not_to include(global_reader)
      end
    end

    # The override is scoped to THIS project: the same global user stays reachable
    # on a DIFFERENT project that has no override. Kills a mutant that drops
    # `project: project` from the exclusion query (excluding the user everywhere).
    it 'still includes the user on another project without an override' do
      other_project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      ActsAsTenant.with_tenant(organisation) do
        create(:project_permission, user: global_reader, project: project, tickets_access: 'no_access')
        expect(described_class.users_with_access(other_project, :read, :tickets)).to include(global_reader)
      end
    end
  end
end
