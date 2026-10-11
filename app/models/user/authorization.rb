# frozen_string_literal: true

class User < ApplicationRecord
  # Authorization surface for User (user.rb split, slice 7/7).
  #
  # The highest-fan-in methods in the project: account_admin_in? (~60 call sites),
  # has_permission_in_organisation? (~30), the role-gated project-access helpers
  # and the two notification view-permission predicates. 18 Pundit policies lean
  # on this group. Like slices 5 and 6 this is a behaviour Concern mixed BACK INTO
  # User: the methods stay instance methods on User, so all of those call sites
  # and policies keep working unchanged with zero migration. Pure refactoring;
  # behaviour is bit-identical to the legacy User code this file replaces.
  #
  # CROSS-CONCERN CALLS resolve at call time because every concern is mixed into
  # the same User instance: account_admin_in? and has_permission_in_organisation?
  # call role_in_organisation (User::OrganisationMembership), and can_view_ticket?
  # / can_view_project? call can_access_project? in this concern. Include order is
  # therefore irrelevant.
  #
  # DELEGATION. can_access_project? and accessible_projects only forward to
  # AccessCheck::ProjectAccessService — the actual access matrix lives there and
  # is tested under spec/services/access_check/. Their default arguments
  # (:read / :tickets) are part of the contract and must be preserved (pinned in
  # spec/models/user/authorization_spec.rb).
  #
  # SCOPE NOTE: Admin::User is a SEPARATE class and does NOT include this concern;
  # the admin backend has its own authorization. This concern is included ONLY in User.
  module Authorization
    extend ActiveSupport::Concern

    # True only when the user is an ACTIVE member of the org AND their role there is
    # account_admin.
    #
    # The active check is part of the question (#603): role_in_organisation answers
    # "which role does this person hold here", a master-data question that survives a
    # deactivation, while this is an authorisation question and must not. Without it
    # a deactivated admin kept the `return scope.all if user.account_admin_in?(...)`
    # shortcut in 18 policy scopes, the widest of the four leaks because it needs no
    # ProjectPermission at all, while ProjectPolicy#show? already denied them.
    def account_admin_in?(organisation)
      return false unless active_member_of_organisation?(organisation)

      role = role_in_organisation(organisation)
      role&.account_admin?
    end

    # Permission check; returns false (not an error) when the user has no role in
    # the org — the guard is what keeps a roleless user from raising NoMethodError.
    def has_permission_in_organisation?(organisation, category, action)
      role = role_in_organisation(organisation)
      return false unless role

      role.has_permission?(category, action)
    end

    # Project access check — delegates to ProjectAccessService.
    def can_access_project?(project, action = :read, area = :tickets)
      AccessCheck::ProjectAccessService.new(self, project).can?(action, area)
    end

    # Projects the user can access — delegates to ProjectAccessService.
    def accessible_projects(organisation, action = :read, area = :tickets)
      AccessCheck::ProjectAccessService.accessible_projects(self, organisation, action: action, area: area)
    end

    # Time-session permission row for a project. find_or_initialize_by => the
    # result may be a new, unsaved record (the settings form relies on this).
    def time_session_permission_for(project)
      time_session_permissions.find_or_initialize_by(project: project)
    end

    # ==========================================================================
    # View-permission predicates used by the notification system
    # ==========================================================================

    def can_view_ticket?(ticket)
      return false unless ticket.is_a?(Ticket)
      return false unless ticket.project

      can_access_project?(ticket.project, :read, :tickets)
    end

    def can_view_project?(project)
      return false unless project.is_a?(Project)

      can_access_project?(project, :read, :general)
    end
  end
end
