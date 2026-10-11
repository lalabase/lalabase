# frozen_string_literal: true

module TagsHelper
  # Tag names the current user may use, scoped to their accessible projects. Feeds the
  # tag-input autocomplete embedded in ticket/note/document forms. Goes through
  # TagPolicy::Scope (single source of truth) — never the full org tag vocabulary.
  def accessible_tag_names
    TagPolicy::Scope.new(current_user, Tag).resolve.order(:name).distinct.pluck(:name)
  end
end
