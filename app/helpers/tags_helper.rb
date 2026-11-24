# frozen_string_literal: true

module TagsHelper
  # Tag names the current user may use, scoped to their accessible projects. Feeds the
  # tag-input autocomplete embedded in ticket/note/document forms. Goes through
  # TagPolicy::Scope (single source of truth) — never the full org tag vocabulary.
  def accessible_tag_names
    TagPolicy::Scope.new(current_user, Tag).resolve.order(:name).distinct.pluck(:name)
  end

  # The head of a column the tag list sorts by (Organisations::TagsController::SORTS,
  # Belegungstabelle F43): a link to the order the next click gives, the word in ink
  # and an arrow where the column is the active order. The search and the page size
  # stay, the page starts again at 1.
  def tag_list_sort_link(key, label)
    active = list_sort == key
    direction = if active
                  list_direction == 'asc' ? 'desc' : 'asc'
                else
                  Organisations::TagsController::SORTS.fetch(key)
                end
    query = { q: list_query.presence, items: (params[:items] if params[:items].is_a?(String)).presence,
              sort: key, direction: direction }.compact
    link_to organisation_tags_path(current_organisation, query),
            class: class_names('inline-flex items-center gap-0.5 transition-colors hover:text-heading', 'text-heading' => active) do
      safe_join([label, (tag.i(class: "bi #{list_direction == 'asc' ? 'bi-arrow-up-short' : 'bi-arrow-down-short'}", 'aria-hidden': true) if active)].compact)
    end
  end

  # aria-sort of that head: the order a screen reader announces for the column.
  def tag_list_aria_sort(key)
    return 'none' unless list_sort == key

    list_direction == 'asc' ? 'ascending' : 'descending'
  end
end
