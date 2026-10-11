# frozen_string_literal: true

module Actors
  # Create or update a DocumentationSet (name, path_prefix, connected repo).
  # Trivial-looking, but a proper actor so Current.user drives activity tracking
  # and the repo/project consistency validation is mapped to a failure Result.
  class SaveDocumentationSet < BaseActor
    def initialize(project:, params:, current_user:, id: nil)
      super()
      @project = project
      @documentation_set = find_or_build_set(project, id)
      @params = params
      @current_user = current_user
    end

    def record
      @documentation_set
    end

    def perform
      raise ActorError, 'Documentation set not found' if @documentation_set.nil?

      @documentation_set.assign_attributes(@params)
      @documentation_set.save!
    end

    private

    # Tenant-scoped lookup; a foreign-tenant id yields nil → "not found" failure.
    def find_or_build_set(project, id)
      if id.present?
        DocumentationSet.where(organisation: project.organisation, id: id).first
      else
        project.documentation_sets.build(organisation: project.organisation)
      end
    end
  end
end
