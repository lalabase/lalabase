# frozen_string_literal: true

# Slice 7a: authorization for meeting analyses. PostPolicy 1:1 (E17) — the area
# gate FIRST, then per-creator visibility. A published analysis is org content, so
# publishing/retracting/deleting needs :meetings write, NOT creator-only (that
# would be the wrong way round). The Scope mirrors PostPolicy: account_admin
# short-circuit, then :meetings-read projects joined via the meeting, filtered to
# what the user may see (public ∪ own private).
class MeetingAnalysisPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      return scope.all if user.account_admin_in?(organisation)

      project_ids = AccessCheck::ProjectAccessService.accessible_project_ids(
        user, organisation, action: :read, area: :meetings
      )
      scope.joins(:meeting).where(meetings: { project_id: project_ids }).visible_to(user)
    end
  end

  # Area gate FIRST (Codex-OV): without it a guessed UUID would be a read bypass —
  # a published analysis in a project the user cannot read must NOT be visible by
  # direct id. Only after the gate does per-creator visibility apply.
  def show?
    return false unless project_policy.area_access?(:meetings, :read) || account_admin?
    return true if account_admin?
    return record.visible_to?(user) if record.private?

    true
  end

  def create?
    write_access?
  end

  # update = the publish/unpublish flip (+ Slice 7b include_in_search) and the
  # re-run. On a PRIVATE analysis that is only for someone who may read it:
  # otherwise any meetings-writer could publish or rewrite somebody else's
  # private work. destroy? stays write-only (curating org content).
  def update?
    write_access? && readable_if_private?
  end

  def publish?
    write_access? && readable_if_private?
  end

  def unpublish?
    write_access?
  end

  def destroy?
    write_access?
  end

  private

  # publish/unpublish/destroy are :meetings write, not creator-only: a published
  # analysis belongs to the org, so any meetings-writer may curate it.
  def write_access?
    project_policy.area_access?(:meetings, :write) || account_admin?
  end

  def readable_if_private?
    account_admin? || !record.private? || record.visible_to?(user)
  end

  def project_policy
    @project_policy ||= ProjectPolicy.new(user, record.meeting.project)
  end
end
