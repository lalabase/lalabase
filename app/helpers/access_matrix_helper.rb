# frozen_string_literal: true

# The tool row of the access overview: the project pill (shared/filter_pill) reads its
# options from here. Each option toggles one project in projects[] and keeps the search,
# and its href (the address without JavaScript) and its owns pairs (the live rewrite by
# query-toggle, against the address the browser is on after a search) come from the same
# list, so the two ways of following an option cannot drift apart.
module AccessMatrixHelper
  def access_matrix_project_options(matrix, organisation)
    chosen = matrix.chosen_project_ids.map(&:to_s)
    matrix.all_projects.map do |project|
      id = project.id.to_s
      toggled = chosen.include?(id) ? chosen - [id] : chosen + [id]
      { value: id, label: project.name, selected: chosen.include?(id),
        url: access_matrix_path_with(organisation, projects: toggled),
        owns: time_filter_owns_pairs(projects: toggled) }
    end
  end

  # The pill's label: the bare name while every project shows, the count once some are chosen.
  def access_matrix_projects_label(matrix)
    return t('views.organisations.access_matrix.filter.projects_label') if matrix.chosen_project_ids.empty?

    t('views.organisations.access_matrix.filter.projects_chosen',
      count: matrix.chosen_project_ids.size, total: matrix.all_projects.size)
  end

  def access_matrix_path_with(organisation, projects:)
    query = params[:q].is_a?(String) ? params[:q].presence : nil
    organisation_access_matrix_index_path(organisation, { q: query, projects: projects.presence }.compact)
  end
end
