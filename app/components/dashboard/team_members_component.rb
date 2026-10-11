# frozen_string_literal: true

class Dashboard::TeamMembersComponent < ViewComponent::Base
  def initialize(project:, user:)
    @project = project
    @user = user
  end

  def should_render?
    Current.project_policy(user, project).area_access?(:members, :read)
  end

  private

  attr_reader :project, :user

  # Everyone with effective access, resolved with provenance — so account admins and
  # global-role members appear too, not just explicit ProjectPermission grants. Mirrors
  # the Team page via the shared ProjectTeamMembers service (no drift between the two).
  def members
    @members ||= AccessCheck::ProjectTeamMembers
                 .new(project: project, current_user: user)
                 .with_access
  end

  # Provenance badge: explain WHY a non-direct member is on the project. An explicit grant
  # (:direct) is the expected case and needs no badge.
  def source_badge(member)
    case member.source
    when :admin then t('dashboard.team_members.source_admin')
    when :role  then t('dashboard.team_members.source_role', role: member.role_title)
    end
  end

  def can_manage_members?
    Current.project_policy(user, project).area_access?(:members, :write)
  end

  def current_organisation
    project.organisation
  end
end
