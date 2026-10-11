# frozen_string_literal: true

# Authorises managing a project's connected git repositories.
#
# The connected repository is a SHARED foundation resource: it feeds project-aware
# chat grounding AND documentation sync (documentation_sets.project_repository_id).
# Access is therefore DECOUPLED from the per-org chat-beta flag — UNLIKE ChatPolicy,
# which stays gated on it (see ChatFeatureGated). Rationale: a documentation set
# REQUIRES a repository but documentation has no beta flag, so a chat-less org must
# still be able to connect one. See doc/repository_connection_relocation_plan.md.
#
#   Read  (index/show — browse the repo list + index history):
#     chats:read OR documentation:write. Deliberately NOT documentation:read
#     (least-privilege — doc *readers* get no repo-page link anywhere in the UI, so
#     we don't widen the read audience until a use-case exists).
#   Write (create/destroy/reindex/update — connect/disconnect/reindex/token rotation):
#     account admin OR chats:write OR documentation:write. All administrative — they
#     mutate stored credentials and the index.
#
# NOTE: the FEATURE behind the policy (indexing, webhooks) stays chat-gated at the
# JOB level (project_indexer_job / repo_reindex_job) and in the repo-page UI. A
# chat-less org can connect a repo (for doc sync) but no code index is ever built.
class ProjectRepositoryPolicy < ApplicationPolicy
  # Own resolution (NOT ChatFeatureGated::ScopeResolution, which since S1 has no
  # consumer at all — ChatPolicy carries its own too):
  # no beta gate, and the visible set is the UNION of the projects whose chats the
  # user can read and whose documentation the user can write.
  class Scope < Scope
    def resolve
      return scope.none unless organisation
      return scope.all if user.account_admin_in?(organisation)

      scope.where(project_id: readable_project_ids)
    end

    private

    def readable_project_ids
      chat_ids = AccessCheck::ProjectAccessService.accessible_project_ids(
        user, organisation, action: :read, area: :chats
      )
      doc_ids = AccessCheck::ProjectAccessService.accessible_project_ids(
        user, organisation, action: :write, area: :documentation
      )
      chat_ids | doc_ids
    end
  end

  def index?
    read_access?
  end

  def show?
    read_access?
  end

  def new?
    create?
  end

  def create?
    account_admin? || write_access?
  end

  def destroy?
    create?
  end

  # Manually re-indexing costs embeddings and mutates the index — same
  # administrative gate as connect/disconnect, NOT the read gate that only lets a
  # user browse the repo list and history.
  def reindex?
    create?
  end

  # Rotating the access token is administrative (it changes stored credentials and
  # re-enables indexing) — same write gate as connect/disconnect.
  def update?
    create?
  end

  private

  # Read = browse the repo list + index history. chats:read OR documentation:write
  # (deliberately NOT documentation:read — least-privilege, see the class comment).
  # `area_access?` treats write as implying read, so a chats:write / documentation:write
  # user passes here too.
  def read_access?
    project_policy.area_access?(:chats, :read) ||
      project_policy.area_access?(:documentation, :write)
  end

  # Write = connect/disconnect/reindex/rotate-token. chats:write OR documentation:write
  # (admins are handled by the explicit account_admin? in create?).
  def write_access?
    project_policy.area_access?(:chats, :write) ||
      project_policy.area_access?(:documentation, :write)
  end

  def project_policy
    @project_policy ||= ProjectPolicy.new(user, record.is_a?(ProjectRepository) ? record.project : record)
  end
end
