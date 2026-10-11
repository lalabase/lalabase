# frozen_string_literal: true

# One member, rendered as a table row on md+ and as a bordered card on mobile (same
# markup, Tailwind display utilities flip `block` <-> `table-row`/`table-cell`).
#
# Renders the view row always, plus a pre-rendered, hidden edit row when the member is
# inline-editable (explicit grant, manager, not your own row). A Stimulus controller
# (`team-member-edit`) toggles between them — no server fetch, no GET-edit route.
class Organisations::Team::MemberRowComponent < ViewComponent::Base
  AREAS = AccessCheck::ProjectMemberAccessResolver::AREAS

  def initialize(member:, project:, organisation:, can_manage:)
    @member = member
    @project = project
    @organisation = organisation
    @can_manage = can_manage
  end

  private

  attr_reader :member, :project, :organisation, :can_manage

  def user
    member.user
  end

  # Inline-editable only for an explicit project grant, by a manager, not your own row.
  # A blocked member keeps this, so a block can be turned back into a real grant
  # without first lifting it.
  def editable_inline?
    can_manage && member.editable? && !member.is_self
  end

  # A role-only member can be promoted to an explicit grant (seeded with their current
  # effective levels so "make explicit" never silently drops access).
  def offer_explicit?
    can_manage && member.role_based? && !member.is_self
  end

  # "Take this person off the project." Offered on every row that still HAS access
  # and is not an admin, including role-based rows: before this, a role-based
  # member had no way off the project at all, and a removed member fell back to
  # their role with the button gone.
  def revocable?
    can_manage && !member.is_self && !member.blocked? && (member.editable? || member.role_based?)
  end

  # The inverse of a block: drop the grant and let the role right apply again.
  def unblockable?
    can_manage && member.blocked? && !member.is_self
  end

  # Provenance line under the name: explains WHY this person is on the project.
  SCOPE = 'views.organisations.project_permissions.member_row'

  def source_label
    return t("#{SCOPE}.source_blocked", role: member.role_title) if member.blocked?

    case member.source
    when :admin then t("#{SCOPE}.source_admin")
    when :direct then t("#{SCOPE}.source_direct")
    when :role then t("#{SCOPE}.source_role", role: member.role_title)
    else ''
    end
  end

  # Only org admins can reach role config, so only they get the link to the source.
  def link_role_source?
    member.role_based? && helpers.current_user.account_admin_in?(organisation)
  end

  def time_label
    case member.time.status
    when :full then t("#{SCOPE}.time_full")
    when :standard then t('views.organisations.project_permissions.time.standard')
    when :custom then t('views.organisations.project_permissions.time.custom')
    else t('views.organisations.project_permissions.levels.no_access')
    end
  end

  def time_settings_path
    perm = member.time.settings_permission
    return nil unless perm && can_manage && !member.is_self

    helpers.time_sessions_settings_organisation_project_project_permission_path(organisation, project, perm)
  end

  def area_label(area)
    t("views.organisations.project_permissions.areas.#{area}")
  end

  def destroy_path
    helpers.organisation_project_project_permission_path(organisation, project, member.permission)
  end

  def revoke_path
    helpers.revoke_organisation_project_project_permissions_path(organisation, project, user_id: user.id)
  end

  def create_path
    helpers.organisation_project_project_permissions_path(organisation, project)
  end
end
