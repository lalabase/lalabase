# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Permission Consolidation', type: :service do
  let(:organisation) { create(:organisation) }
  let(:project) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project, organisation: organisation)
    end
  end

  # Regular user with a role that has NO global permissions
  let(:regular_role) do
    ActsAsTenant.with_tenant(organisation) do
      create(:role, organisation: organisation, title: 'regular_user')
    end
  end
  let(:user) { create(:user) }

  # Admin user
  let(:admin_user) { create(:user) }

  # User with global read permission for tickets
  let(:global_read_role) do
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation)
      create(:project_read_permission, role: role, area: 'tickets')
      role
    end
  end
  let(:global_read_user) { create(:user) }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: regular_role)
      create(:membership, user: admin_user, organisation: organisation, role: create(:admin_role, organisation: organisation))
      create(:membership, user: global_read_user, organisation: organisation, role: global_read_role)
    end
  end

  # =========================================================================
  # Scenario 1: Admin bypass — always true
  # =========================================================================
  describe 'Scenario 1: Admin bypass' do
    it 'ProjectAccessService grants access' do
      ActsAsTenant.with_tenant(organisation) do
        service = AccessCheck::ProjectAccessService.new(admin_user, project)
        expect(service.can?(:read, :tickets)).to be true
        expect(service.can?(:write, :tickets)).to be true
      end
    end

    it 'ProjectPolicy grants access' do
      ActsAsTenant.with_tenant(organisation) do
        policy = ProjectPolicy.new(admin_user, project)
        expect(policy.area_access?(:tickets, :read)).to be true
        expect(policy.area_access?(:tickets, :write)).to be true
      end
    end

    it 'User#can_access_project? grants access' do
      ActsAsTenant.with_tenant(organisation) do
        expect(admin_user.can_access_project?(project, :read, :tickets)).to be true
        expect(admin_user.can_access_project?(project, :write, :tickets)).to be true
      end
    end
  end

  # =========================================================================
  # Scenario 2: no_access override with global role — should be FALSE
  # This is the known bug in User#can_access_project? and User#accessible_projects
  # =========================================================================
  describe 'Scenario 2: no_access override with global role' do
    before do
      ActsAsTenant.with_tenant(organisation) do
        # Global read role for tickets is already assigned to global_read_user
        # Now add explicit no_access for this specific project
        create(:project_permission,
               user: global_read_user,
               project: project,
               tickets_access: 'no_access')
      end
    end

    it 'ProjectAccessService correctly denies access' do
      ActsAsTenant.with_tenant(organisation) do
        service = AccessCheck::ProjectAccessService.new(global_read_user, project)
        expect(service.can?(:read, :tickets)).to be false
      end
    end

    it 'ProjectPolicy correctly denies access' do
      ActsAsTenant.with_tenant(organisation) do
        policy = ProjectPolicy.new(global_read_user, project)
        expect(policy.area_access?(:tickets, :read)).to be false
      end
    end

    it 'User#can_access_project? correctly denies access' do
      ActsAsTenant.with_tenant(organisation) do
        expect(global_read_user.can_access_project?(project, :read, :tickets)).to be false
      end
    end
  end

  # =========================================================================
  # Scenario 3: read_only — read allowed, write denied
  # =========================================================================
  describe 'Scenario 3: read_only permission' do
    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:project_permission,
               user: user,
               project: project,
               tickets_access: 'read_only')
      end
    end

    it 'ProjectAccessService allows read, denies write' do
      ActsAsTenant.with_tenant(organisation) do
        service = AccessCheck::ProjectAccessService.new(user, project)
        expect(service.can?(:read, :tickets)).to be true
        expect(service.can?(:write, :tickets)).to be false
      end
    end

    it 'ProjectPolicy allows read, denies write' do
      ActsAsTenant.with_tenant(organisation) do
        policy = ProjectPolicy.new(user, project)
        expect(policy.area_access?(:tickets, :read)).to be true
        expect(policy.area_access?(:tickets, :write)).to be false
      end
    end

    it 'User#can_access_project? allows read, denies write' do
      ActsAsTenant.with_tenant(organisation) do
        expect(user.can_access_project?(project, :read, :tickets)).to be true
        expect(user.can_access_project?(project, :write, :tickets)).to be false
      end
    end
  end

  # =========================================================================
  # Scenario 4: read_write — both allowed
  # =========================================================================
  describe 'Scenario 4: read_write permission' do
    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:project_permission,
               user: user,
               project: project,
               tickets_access: 'read_write')
      end
    end

    it 'ProjectAccessService allows both' do
      ActsAsTenant.with_tenant(organisation) do
        service = AccessCheck::ProjectAccessService.new(user, project)
        expect(service.can?(:read, :tickets)).to be true
        expect(service.can?(:write, :tickets)).to be true
      end
    end

    it 'ProjectPolicy allows both' do
      ActsAsTenant.with_tenant(organisation) do
        policy = ProjectPolicy.new(user, project)
        expect(policy.area_access?(:tickets, :read)).to be true
        expect(policy.area_access?(:tickets, :write)).to be true
      end
    end

    it 'User#can_access_project? allows both' do
      ActsAsTenant.with_tenant(organisation) do
        expect(user.can_access_project?(project, :read, :tickets)).to be true
        expect(user.can_access_project?(project, :write, :tickets)).to be true
      end
    end
  end

  # =========================================================================
  # Scenario 5: No ProjectPermission — global role grants access
  # =========================================================================
  describe 'Scenario 5: global role fallback (no ProjectPermission)' do
    it 'ProjectAccessService grants access via role' do
      ActsAsTenant.with_tenant(organisation) do
        service = AccessCheck::ProjectAccessService.new(global_read_user, project)
        expect(service.can?(:read, :tickets)).to be true
        expect(service.can?(:write, :tickets)).to be false
      end
    end

    it 'ProjectPolicy grants access via role' do
      ActsAsTenant.with_tenant(organisation) do
        policy = ProjectPolicy.new(global_read_user, project)
        expect(policy.area_access?(:tickets, :read)).to be true
        expect(policy.area_access?(:tickets, :write)).to be false
      end
    end

    it 'User#can_access_project? grants access via role' do
      ActsAsTenant.with_tenant(organisation) do
        expect(global_read_user.can_access_project?(project, :read, :tickets)).to be true
        expect(global_read_user.can_access_project?(project, :write, :tickets)).to be false
      end
    end
  end

  # =========================================================================
  # Scenario 6: No permission at all — denied
  # =========================================================================
  describe 'Scenario 6: no permission at all' do
    it 'ProjectAccessService denies access' do
      ActsAsTenant.with_tenant(organisation) do
        service = AccessCheck::ProjectAccessService.new(user, project)
        expect(service.can?(:read, :tickets)).to be false
        expect(service.can?(:write, :tickets)).to be false
      end
    end

    it 'ProjectPolicy denies access' do
      ActsAsTenant.with_tenant(organisation) do
        policy = ProjectPolicy.new(user, project)
        expect(policy.area_access?(:tickets, :read)).to be false
        expect(policy.area_access?(:tickets, :write)).to be false
      end
    end

    it 'User#can_access_project? denies access' do
      ActsAsTenant.with_tenant(organisation) do
        expect(user.can_access_project?(project, :read, :tickets)).to be false
        expect(user.can_access_project?(project, :write, :tickets)).to be false
      end
    end
  end

  # =========================================================================
  # Scenario 7: accessible_projects no_access exclusion
  # =========================================================================
  describe 'Scenario 7: accessible_projects with no_access exclusion' do
    let!(:project2) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation)
      end
    end

    before do
      ActsAsTenant.with_tenant(organisation) do
        # Explicitly block global_read_user from project via no_access on ALL areas
        create(:project_permission,
               user: global_read_user,
               project: project,
               tickets_access: 'no_access',
               notes_access: 'no_access',
               chats_access: 'no_access',
               documents_access: 'no_access')
      end
    end

    it 'ProjectAccessService.accessible_projects excludes no_access project' do
      ActsAsTenant.with_tenant(organisation) do
        result = AccessCheck::ProjectAccessService.accessible_projects(global_read_user, organisation).to_a
        expect(result).to include(project2)
        expect(result).not_to include(project)
      end
    end

    it 'User#accessible_projects excludes no_access project' do
      ActsAsTenant.with_tenant(organisation) do
        result = global_read_user.accessible_projects(organisation, :read, :tickets)
        expect(result).to include(project2)
        expect(result).not_to include(project)
      end
    end
  end
end
