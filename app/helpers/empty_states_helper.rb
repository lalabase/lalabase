# frozen_string_literal: true

# First-use detection for the project-area lists: "the area holds no records
# at all" — as opposed to "records exist but the current filter/search matched
# nothing". Single source for BOTH sides of the reduced first-use rule (see
# the style guide page /style-guide/empty_states):
#   * the index views hide the filter/search chrome on first use,
#   * the results partials pick the first-time explainer empty state
#     (vs. the plain no-results card when only the filter came up empty).
module EmptyStatesHelper
  # exists? (not none?/empty?) on purpose, here and below: it always queries
  # the DB, while none? counts unsaved records that view code may have built
  # into the association target (the tickets index builds a modal ticket via
  # @project.tickets.build BEFORE this check runs).
  def tickets_first_use?(project)
    !project.tickets.exists?
  end

  # Mirrors what the knowledge list can show for THIS user: notes and documents
  # count only when the user may read them (can_access_* are knowledge
  # controller helper_methods), versionless document shells never show up.
  def knowledge_first_use?(project)
    return false if can_access_notes? && project.notes.exists?

    !(can_access_documents? && project.documents.where.not(current_version_id: nil).exists?)
  end

  def meetings_first_use?(project)
    !project.meetings.exists?
  end
end

# The time list has no entry here: it is one list for the organisation, and
# "first use" there is judged by what THIS reader may see
# (Organisations::TimeSessionsController#time_sessions_first_use?).
