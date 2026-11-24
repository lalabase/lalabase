# frozen_string_literal: true

# The tags of an organisation are one shared vocabulary. Anyone who may write an
# entry adds to it by tagging (Taggable#tag_list=); nobody creates a tag by hand.
# Looking after it, the list with its counts, renaming, merging and deleting, is
# the management section "Tags", and that is the account admins' (user,
# 2026-11-24). Until then the creator of a tag could rename and delete it as
# well, on pages nothing linked to.
class TagPolicy < ApplicationPolicy
  def index?
    account_admin?
  end

  def update?
    account_admin?
  end

  def merge?
    account_admin?
  end

  def destroy?
    account_admin?
  end

  class Scope < Scope
    # Org admins see every tag (including unused ones). Everyone else only sees tags that
    # are actually used in a project they can access — so the tag field's suggestions
    # (TagsHelper) and the bulk change (Tickets::BulkFields) never leak foreign-project
    # tag names.
    def resolve
      return scope.all if user.account_admin_in?(organisation)

      accessible_project_ids =
        AccessCheck::ProjectAccessService.accessible_projects(user, organisation).select(:id)
      scope.used_in_projects(accessible_project_ids)
    end
  end
end
