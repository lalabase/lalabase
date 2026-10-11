# frozen_string_literal: true

module Lalabase
  # Resolves the set of ProjectRepository IDs in scope for a project-aware query.
  # One caller left since projekt_chat_abbau: the repo-scoped tools
  # (Tools::SearchCodeSymbols, Tools::GetSymbolDetails via Tools::Base). The RAG
  # retriever's code layer, the other half of "shared rule", went with the surface
  # that paid for it.
  #
  # - no project → [] (defensive; both callers resolve a project before getting here)
  # - otherwise → the repos of that project, scoped to the organisation
  # - a pin NARROWS that set, it never replaces it
  #
  # ⚠️ The pin used to be passed straight through as `[pinned_repo_id]`, skipping the
  # project and organisation filters entirely, and the comment here said that was safe
  # because `Chat#project_repository_belongs_to_project` had checked it upstream.
  # projekt_chat_abbau deleted that validation: it compared the repository's project
  # against the CHAT'S, and no chat carries a project any more, so it could never pass
  # again. What was left was a guarantee resting on "nothing writes the column" -- true
  # today (`project_repository_id` is in no permit), and exactly the kind of guarantee
  # that dies quietly when somebody adds a pin back or imports old rows.
  #
  # So the pin is intersected instead of trusted. A pin naming a repository of another
  # project (or another organisation) now yields [], and the caller answers "this
  # project has no indexed repositories" rather than searching a foreign one.
  module RepoScope
    module_function

    # @param project [Project, nil]
    # @param organisation [Organisation]
    # @param pinned_repo_id [String, nil] ProjectRepository UUID or nil
    # @return [Array<String>] ProjectRepository UUIDs
    def ids_for(project:, organisation:, pinned_repo_id:)
      return [] if project.nil?

      repos = ProjectRepository.where(project_id: project.id, organisation_id: organisation.id)
      repos = repos.where(id: pinned_repo_id) if pinned_repo_id.present?
      repos.pluck(:id)
    end
  end
end
