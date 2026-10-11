# frozen_string_literal: true

require 'rails_helper'

# Specs for User::Authorization — the authorization surface extracted from the
# User god-class (user.rb split, slice 7/7).
#
# WHAT THIS GUARDS
# This slice moves the highest-fan-in methods in the whole project
# (account_admin_in?, has_permission_in_organisation?, role-gated project
# access, the notification view-permission helpers) into a Concern mixed BACK
# INTO User. The methods stay instance methods on User, so all ~130 call sites
# and the 18 Pundit policies that lean on them keep working unchanged with zero
# migration. The slice is a pure refactoring: behaviour must stay bit-identical
# to the legacy User methods. Most examples here are CHARACTERIZATION tests —
# they pin what the app already does, not new requirements.
#
# SECURITY CONTRACT. Because this is the authorization layer, both directions
# matter: positive examples pin that the entitled get access, negative examples
# pin that the unentitled are refused. The negative cases (no role => false, no
# permission => false, wrong area/action => false) are the ones a bad refactor
# would quietly break, so they are deliberate, not redundant.
#
# DELEGATION. can_access_project? / accessible_projects only forward to
# AccessCheck::ProjectAccessService; the real access matrix is tested in
# spec/services/access_check/. The delegation examples here pin the forwarding
# AND the default arguments (:read / :tickets), which the integration examples
# below cannot catch because they always pass the action/area explicitly.
#
# NOTE ON SCOPE: Admin::User is a SEPARATE class and does NOT include this
# concern; the admin backend has its own authorization. This file pins the
# User-side behaviour only.
RSpec.describe User, type: :model do
  describe '#account_admin_in?' do
    let(:user) { create(:user) }
    let(:organisation) { create(:organisation) }

    context 'when user is an account admin in the organisation' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          admin_role = create(:role, organisation: organisation, title: 'account_admin')
          create(:membership, user: user, organisation: organisation, role: admin_role)
        end
      end

      it 'returns true' do
        ActsAsTenant.with_tenant(organisation) do
          expect(user.account_admin_in?(organisation)).to be true
        end
      end
    end

    context 'when user is not an account admin in the organisation' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          regular_role = create(:role, organisation: organisation, title: 'regular_user')
          create(:membership, user: user, organisation: organisation, role: regular_role)
        end
      end

      it 'returns false' do
        ActsAsTenant.with_tenant(organisation) do
          expect(user.account_admin_in?(organisation)).to be false
        end
      end
    end

    # account_admin_in? has TWO falsy outcomes that look identical in a policy
    # `if`, but are different return VALUES — and only `false` was pinned before:
    #   - a non-admin ROLE          -> role.account_admin? -> false (context above)
    #   - no role / no membership   -> role_in_organisation is nil -> nil
    # The nil branch is the one that catches dropping the safe navigation:
    # `role&.account_admin?` -> `role.account_admin?` would NoMethodError here.
    # (Note: create(:membership, role: nil) does NOT reach this — Membership's
    # after_create assigns the org default role, so role_id must be nulled
    # explicitly. The pre-existing "role: nil" example silently tested the
    # default-role path, i.e. `false`, NOT the nil path.)
    context 'when the membership has no role (role_id NULL)' do
      it 'returns nil' do
        ActsAsTenant.with_tenant(organisation) do
          membership = create(:membership, user: user, organisation: organisation, role: nil)
          membership.update_column(:role_id, nil) # must skip assign_default_role
          expect(User.find(user.id).account_admin_in?(organisation)).to be_nil
        end
      end
    end

    context 'when the user has no membership in the organisation' do
      # false, not nil: the active-membership check added in #603 answers first and a
      # predicate should say no rather than "no value". The nil below is a different
      # case, an ACTIVE membership that carries no role at all, where role&.
      # account_admin? still short-circuits.
      it 'returns false' do
        expect(user.account_admin_in?(organisation)).to be(false)
      end
    end

    context 'when the membership exists but is deactivated' do
      it 'returns false, and the role is still readable as master data' do
        ActsAsTenant.with_tenant(organisation) do
          admin_role = create(:role, organisation: organisation, title: 'account_admin')
          create(:membership, user: user, organisation: organisation, role: admin_role, active: false)
          reloaded = User.find(user.id)

          expect(reloaded.account_admin_in?(organisation)).to be(false)
          expect(reloaded.role_in_organisation(organisation)).to eq(admin_role)
        end
      end
    end

    # CROSS-ORG: being an admin in ONE org must not make account_admin_in?
    # truthy for ANOTHER org (authorization is strictly per-org).
    it 'is false for an organisation the user is an admin of only elsewhere' do
      other = create(:organisation)
      ActsAsTenant.with_tenant(organisation) do
        admin_role = create(:role, organisation: organisation, title: 'account_admin')
        create(:membership, user: user, organisation: organisation, role: admin_role)
      end
      expect(user.account_admin_in?(other)).to be(false)
    end
  end

  describe '#has_permission_in_organisation?' do
    let(:user) { create(:user) }
    let(:organisation) { create(:organisation) }
    let(:role) do
      ActsAsTenant.with_tenant(organisation) do
        create(:role, organisation: organisation)
      end
    end

    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, role: role)
      end
    end

    context 'when user has the specified permission' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          create(:permission, role: role, category: 'projects', action: 'create_new_projects', allowed: true)
        end
      end

      it 'returns true' do
        ActsAsTenant.with_tenant(organisation) do
          expect(user.has_permission_in_organisation?(organisation, 'projects', 'create_new_projects')).to be true
        end
      end
    end

    context 'when user does not have the specified permission' do
      it 'returns false' do
        ActsAsTenant.with_tenant(organisation) do
          expect(user.has_permission_in_organisation?(organisation, 'projects', 'create_new_projects')).to be false
        end
      end
    end

    # The `return false unless role` guard. A user with NO role in the queried
    # org must be refused WITHOUT raising — dropping the guard would call
    # has_permission? on nil and blow up (NoMethodError) instead of returning
    # false. This is the security-critical negative path.
    context 'when user has no role in the organisation' do
      let(:other_organisation) { create(:organisation) }

      it 'returns false' do
        expect(user.has_permission_in_organisation?(other_organisation, 'projects', 'create_new_projects')).to be false
      end
    end

    # Same guard, different path: here the membership EXISTS but its role is nil
    # (role_id nulled past the default-role callback). role_in_organisation
    # returns nil, so `return false unless role` must still short-circuit — i.e.
    # "has a membership" does NOT imply "has permissions". Dropping the guard
    # would call has_permission? on nil and raise instead of returning false.
    context 'when the membership has no role' do
      it 'returns false without raising' do
        ActsAsTenant.with_tenant(organisation) do
          user.memberships.find_by(organisation_id: organisation.id)
              .update_column(:role_id, nil) # must skip assign_default_role
          expect(User.find(user.id)
                     .has_permission_in_organisation?(organisation, 'projects', 'create_new_projects')).to be false
        end
      end
    end
  end

  describe '#can_access_project?' do
    let(:user) { create(:user) }
    let(:organisation) { create(:organisation) }
    let(:project) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation)
      end
    end

    context 'when user is an account admin' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          admin_role = create(:role, organisation: organisation, title: 'account_admin')
          create(:membership, user: user, organisation: organisation, role: admin_role)
        end
      end

      it 'returns true regardless of action and area' do
        ActsAsTenant.with_tenant(organisation) do
          expect(user.can_access_project?(project, :read, :tickets)).to be true
          expect(user.can_access_project?(project, :write, :notes)).to be true
        end
      end
    end

    context 'when user has global read permission for all projects' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          role = create(:role, organisation: organisation)
          create(:permission, role: role, category: 'projects', action: 'read_access_tickets_all_projects', allowed: true)
          create(:membership, user: user, organisation: organisation, role: role)
        end
      end

      it 'returns true for read actions' do
        ActsAsTenant.with_tenant(organisation) do
          expect(user.can_access_project?(project, :read, :tickets)).to be true
        end
      end

      it 'returns false for write actions' do
        ActsAsTenant.with_tenant(organisation) do
          expect(user.can_access_project?(project, :write, :tickets)).to be false
        end
      end
    end

    context 'when user has global write permission for all projects' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          role = create(:role, organisation: organisation)
          create(:permission, role: role, category: 'projects', action: 'write_access_tickets_all_projects', allowed: true)
          create(:membership, user: user, organisation: organisation, role: role)
        end
      end

      it 'returns true for both read and write actions' do
        ActsAsTenant.with_tenant(organisation) do
          expect(user.can_access_project?(project, :read, :tickets)).to be true
          expect(user.can_access_project?(project, :write, :tickets)).to be true
        end
      end
    end

    context 'when user has specific project permissions' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: user, organisation: organisation)
        end
      end

      it 'returns true for areas with read_only access when reading' do
        ActsAsTenant.with_tenant(organisation) do
          create(:project_permission, user: user, project: project, tickets_access: 'read_only')
          expect(user.can_access_project?(project, :read, :tickets)).to be true
        end
      end

      it 'returns false for areas with read_only access when writing' do
        ActsAsTenant.with_tenant(organisation) do
          create(:project_permission, user: user, project: project, tickets_access: 'read_only')
          expect(user.can_access_project?(project, :write, :tickets)).to be false
        end
      end

      it 'returns true for areas with read_write access when reading or writing' do
        ActsAsTenant.with_tenant(organisation) do
          create(:project_permission, user: user, project: project, notes_access: 'read_write')
          expect(user.can_access_project?(project, :read, :notes)).to be true
          expect(user.can_access_project?(project, :write, :notes)).to be true
        end
      end

      it 'returns false for areas with no_access' do
        ActsAsTenant.with_tenant(organisation) do
          create(:project_permission, user: user, project: project, chats_access: 'no_access')
          expect(user.can_access_project?(project, :read, :chats)).to be false
          expect(user.can_access_project?(project, :write, :chats)).to be false
        end
      end
    end

    context 'when user has no permission for the project' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: user, organisation: organisation)
        end
      end

      it 'returns false' do
        ActsAsTenant.with_tenant(organisation) do
          expect(user.can_access_project?(project, :read, :tickets)).to be false
          expect(user.can_access_project?(project, :write, :tickets)).to be false
        end
      end
    end

    # Pure delegation + DEFAULT ARGUMENTS. The integration examples above always
    # pass action/area explicitly, so they cannot catch a mutated default
    # (e.g. `action = :write`). This example pins that a bare can_access_project?
    # forwards (self, project) to the service and asks for :read / :tickets.
    it 'forwards to ProjectAccessService#can? with the default :read and :tickets' do
      service = instance_double(AccessCheck::ProjectAccessService)
      expect(AccessCheck::ProjectAccessService).to receive(:new).with(user, project).and_return(service)
      expect(service).to receive(:can?).with(:read, :tickets).and_return(true)

      expect(user.can_access_project?(project)).to be true
    end
  end

  describe '#accessible_projects' do
    let(:user) { create(:user) }
    let(:organisation) { create(:organisation) }
    let(:project1) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation)
      end
    end
    let(:project2) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation)
      end
    end
    let(:project3) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation)
      end
    end

    context 'when user is an account admin' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          admin_role = create(:role, organisation: organisation, title: 'account_admin')
          create(:membership, user: user, organisation: organisation, role: admin_role)
        end
      end

      it 'returns all projects in the organisation' do
        ActsAsTenant.with_tenant(organisation) do
          # Force lazy let creation before querying
          project1
          project2
          project3
          projects = user.accessible_projects(organisation).to_a
          expect(projects).to include(project1, project2, project3)
          expect(projects.count).to eq(3)
        end
      end
    end

    context 'when user has global read permission' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          role = create(:role, organisation: organisation)
          create(:permission, role: role, category: 'projects', action: 'read_access_tickets_all_projects', allowed: true)
          create(:membership, user: user, organisation: organisation, role: role)
        end
      end

      it 'returns all projects for read access' do
        ActsAsTenant.with_tenant(organisation) do
          project1
          project2
          project3
          projects = user.accessible_projects(organisation, :read, :tickets).to_a
          expect(projects).to include(project1, project2, project3)
          expect(projects.count).to eq(3)
        end
      end

      it 'returns no projects for write access' do
        ActsAsTenant.with_tenant(organisation) do
          projects = user.accessible_projects(organisation, :write, :tickets)
          expect(projects).to be_empty
        end
      end
    end

    context 'when user has global write permission' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          role = create(:role, organisation: organisation)
          create(:permission, role: role, category: 'projects', action: 'write_access_tickets_all_projects', allowed: true)
          create(:membership, user: user, organisation: organisation, role: role)
        end
      end

      it 'returns all projects for both read and write access' do
        ActsAsTenant.with_tenant(organisation) do
          project1
          project2
          project3
          read_projects = user.accessible_projects(organisation, :read, :tickets).to_a
          expect(read_projects).to include(project1, project2, project3)
          expect(read_projects.count).to eq(3)

          write_projects = user.accessible_projects(organisation, :write, :tickets).to_a
          expect(write_projects).to include(project1, project2, project3)
          expect(write_projects.count).to eq(3)
        end
      end
    end

    context 'when user has specific project permissions' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: user, organisation: organisation)
          create(:project_permission, user: user, project: project1, tickets_access: 'read_only')
          create(:project_permission, user: user, project: project2, tickets_access: 'read_write')
          # No permission for project3
        end
      end

      it 'returns projects with read or read_write access for read actions' do
        ActsAsTenant.with_tenant(organisation) do
          projects = user.accessible_projects(organisation, :read, :tickets).to_a
          expect(projects).to include(project1, project2)
          expect(projects).not_to include(project3)
          expect(projects.count).to eq(2)
        end
      end

      it 'returns only projects with read_write access for write actions' do
        ActsAsTenant.with_tenant(organisation) do
          projects = user.accessible_projects(organisation, :write, :tickets).to_a
          expect(projects).to include(project2)
          expect(projects).not_to include(project1, project3)
          expect(projects.count).to eq(1)
        end
      end

      it 'respects the specified area' do
        ActsAsTenant.with_tenant(organisation) do
          create(:project_permission, user: user, project: project3, notes_access: 'read_write')

          # For tickets area
          ticket_projects = user.accessible_projects(organisation, :write, :tickets).to_a
          expect(ticket_projects).to include(project2)
          expect(ticket_projects).not_to include(project1, project3)

          # For notes area
          note_projects = user.accessible_projects(organisation, :write, :notes).to_a
          expect(note_projects).to include(project3)
          expect(note_projects).not_to include(project1, project2)
        end
      end
    end

    # Pure delegation + DEFAULT ARGUMENTS, same reasoning as can_access_project?.
    # A bare accessible_projects(org) must forward action: :read, area: :tickets.
    it 'forwards to ProjectAccessService.accessible_projects with the default :read and :tickets' do
      expect(AccessCheck::ProjectAccessService).to receive(:accessible_projects)
        .with(user, organisation, action: :read, area: :tickets).and_return([])

      expect(user.accessible_projects(organisation)).to eq([])
    end
  end

  describe '#time_session_permission_for' do
    let(:user) { create(:user) }
    let(:organisation) { create(:organisation) }
    let(:project) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation)
      end
    end

    it 'returns the existing permission when one exists' do
      ActsAsTenant.with_tenant(organisation) do
        existing = create(:time_session_permission, user: user, project: project)
        expect(user.time_session_permission_for(project)).to eq(existing)
      end
    end

    # find_or_initialize_by: when none exists, hand back an UNPERSISTED record
    # already scoped to this user + project (the settings form relies on this to
    # render defaults without writing a row). Pinning new_record? + the
    # associations kills a drift to find_or_create_by or a plain new.
    it 'initialises a new unpersisted permission scoped to the user' do
      ActsAsTenant.with_tenant(organisation) do
        result = user.time_session_permission_for(project)
        expect(result).to be_a(TimeSessionPermission)
        expect(result).to be_new_record
        expect(result.project).to eq(project)
        expect(result.user).to eq(user)
      end
    end

    # CROSS-USER ISOLATION: scoped through THIS user's association. Another
    # user's permission for the SAME project must NOT be returned — the call
    # must initialise a fresh record. Kills dropping the user scope (e.g.
    # TimeSessionPermission.find_or_initialize_by instead of
    # time_session_permissions.find_or_initialize_by), which would hand back the
    # foreign row.
    it "ignores another user's permission for the same project" do
      other_user = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session_permission, user: other_user, project: project)
        result = user.time_session_permission_for(project)
        expect(result).to be_new_record
        expect(result.user).to eq(user)
      end
    end
  end

  describe '#can_view_ticket?' do
    let(:user) { create(:user) }
    let(:organisation) { create(:organisation) }

    it 'returns false for a non-Ticket argument' do
      expect(user.can_view_ticket?('not a ticket')).to be false
      expect(user.can_view_ticket?(nil)).to be false
    end

    it 'returns false for a Ticket without a project' do
      # Ticket is acts_as_tenant, so even instantiating it needs a tenant.
      ActsAsTenant.with_tenant(organisation) do
        expect(user.can_view_ticket?(Ticket.new)).to be false
      end
    end

    # Delegation pin: a viewable ticket is decided by project access for the
    # :read action in the :tickets area. The .with(...) matcher is what kills the
    # area mutant (:tickets -> :general) and the action mutant.
    it 'delegates to can_access_project? with the ticket project, :read and :tickets' do
      ActsAsTenant.with_tenant(organisation) do
        project = create(:project, organisation: organisation)
        ticket = Ticket.new(project: project)
        expect(user).to receive(:can_access_project?).with(project, :read, :tickets).and_return(true)

        expect(user.can_view_ticket?(ticket)).to be true
      end
    end
  end

  describe '#can_view_project?' do
    let(:user) { create(:user) }
    let(:organisation) { create(:organisation) }

    it 'returns false for a non-Project argument' do
      expect(user.can_view_project?('not a project')).to be false
      expect(user.can_view_project?(nil)).to be false
    end

    # Same delegation shape as can_view_ticket?, but the notification "can view
    # this project" check uses the :general area, not :tickets. The .with(...)
    # matcher pins that distinction.
    it 'delegates to can_access_project? with the project, :read and :general' do
      ActsAsTenant.with_tenant(organisation) do
        project = create(:project, organisation: organisation)
        expect(user).to receive(:can_access_project?).with(project, :read, :general).and_return(true)

        expect(user.can_view_project?(project)).to be true
      end
    end
  end

  # COHESIVE FUNCTIONAL BLOCK: can_view_ticket? / can_view_project? all the way
  # through can_access_project? -> AccessCheck::ProjectAccessService -> the real
  # role/permission matrix, with NO stubbing. The delegation specs above prove
  # the forwarding in isolation; these prove the predicates actually GATE on real
  # access — i.e. admin status flows through to ticket/project visibility and an
  # outsider is denied. A regression that severed the chain (e.g. can_access_project?
  # hard-wired to true/false, or a swapped area) would slip past the stubbed
  # delegation specs but redden here.
  describe 'view-permission predicates end-to-end (no stubbing)' do
    let(:organisation) { create(:organisation) }
    let(:project) do
      ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    end
    let(:ticket) do
      ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, organisation: organisation) }
    end

    context 'an account admin of the organisation' do
      let(:admin) do
        member = create(:user)
        ActsAsTenant.with_tenant(organisation) do
          admin_role = create(:role, organisation: organisation, title: 'account_admin')
          create(:membership, user: member, organisation: organisation, role: admin_role)
        end
        member
      end

      it 'can view tickets and projects in that organisation' do
        ActsAsTenant.with_tenant(organisation) do
          expect(admin.can_view_ticket?(ticket)).to be true
          expect(admin.can_view_project?(project)).to be true
        end
      end
    end

    context 'an outsider with no membership' do
      let(:outsider) { create(:user) }

      it 'can view neither the ticket nor the project' do
        ActsAsTenant.with_tenant(organisation) do
          expect(outsider.can_view_ticket?(ticket)).to be false
          expect(outsider.can_view_project?(project)).to be false
        end
      end
    end

    # The :tickets vs :general area distinction, proven END-TO-END (the delegation
    # specs above pin it only through stubs). A member with read_only TICKETS
    # access sees the ticket but NOT the project — project visibility is the
    # :general area, which a tickets permission does not grant. A mutant that
    # swapped the area in either predicate would flip one of these and redden,
    # which the stubbed specs alone could not surface.
    context 'a member with read_only tickets access but no general access' do
      let(:member) do
        user = create(:user)
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: user, organisation: organisation)
          create(:project_permission, user: user, project: project, tickets_access: 'read_only')
        end
        user
      end

      it 'can view the ticket but not the project' do
        ActsAsTenant.with_tenant(organisation) do
          expect(member.can_view_ticket?(ticket)).to be true
          expect(member.can_view_project?(project)).to be false
        end
      end
    end
  end
end
