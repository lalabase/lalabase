# frozen_string_literal: true

module Lalabase
  module Tools
    # Returns the high-level project Vision (Layer 4 of the project index):
    # a multi-paragraph summary of what the project is, who it serves, and
    # what the main building blocks are.
    #
    # Functionally the tool-side variant of ProjectRag::Retriever#fetch_vision.
    # Useful when the LLM realised mid-answer that it needs the broader
    # context that the baseline retrieval would have skipped (e.g. when the
    # initial user message looked code-specific but turned out to be conceptual).
    class GetProjectVision < Base
      MAX_CONTENT_LEN = 4000

      # Its reach is a rights question (Base.resolve_code_project ->
      # Scope#code_project_ids -> ProjectRepositoryPolicy::Scope), so the Runner's
      # fail-closed bar must refuse the call when no user is in the context.
      def self.requires_actor?
        true
      end

      def self.tool_name
        'get_project_vision'
      end

      def self.description
        'Returns the high-level project Vision (Layer 4): a multi-paragraph ' \
          'summary of what the project is and what the main building blocks are. ' \
          'Use when the user asks broad "what does this project do" questions. ' \
          'A vision belongs to ONE project. In an org-wide assistant thread, name ' \
          'the project when several have connected code; the answer says which ' \
          'project it is about in its first line.'
      end

      def self.input_schema
        { type: 'object', properties: {}.merge(PROJECT_FILTER_SCHEMA), required: [] }
      end

      def self.execute(args:, context:)
        args = symbolized(args)
        project = resolve_code_project(args, context)
        return project if project.is_a?(Result)

        coverage = code_coverage(args, context, project)
        vision = ProjectLayer4Vision.find_by(project_id: project.id,
                                             organisation_id: context.organisation.id)
        if vision.nil?
          return Result.new(content: with_code_project(context, project, 'No vision has been indexed for this project yet.'),
                            citations: [], kind: :empty, coverage: coverage)
        end

        Result.new(
          content: with_code_project(context, project, vision.content.to_s[0, MAX_CONTENT_LEN]),
          citations: [Lalabase::Citations.vision(vision)],
          coverage: coverage
        )
      end
    end
  end
end
