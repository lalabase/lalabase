# frozen_string_literal: true

module Lalabase
  module Tools
    # Lists the project's capabilities (Layer 3) by name. Overview-only tool
    # — emits no citations. Use as a stepping stone to GetCapabilityDetails
    # or SearchCodeSymbols. Capped at MAX_LISTED to keep the prompt bounded;
    # excess is hinted at via a "... and more" footer.
    class ListCapabilities < Base
      MAX_LISTED = 50

      # Its reach is a rights question (Base.resolve_code_project) -- see
      # GetProjectVision for the whole reason.
      def self.requires_actor?
        true
      end

      def self.tool_name
        'list_capabilities'
      end

      def self.description
        'Lists the project capabilities (Layer 3) by name. Each capability ' \
          'represents a coherent feature area. Use to survey what the project ' \
          'can do before drilling into one via get_capability_details. ' \
          'Capabilities belong to ONE project. In an org-wide assistant thread, ' \
          'name the project when several have connected code; the answer says ' \
          'which project it is about in its first line.'
      end

      def self.input_schema
        { type: 'object', properties: {}.merge(PROJECT_FILTER_SCHEMA), required: [] }
      end

      def self.execute(args:, context:)
        args = symbolized(args)
        project = resolve_code_project(args, context)
        return project if project.is_a?(Result)

        coverage = code_coverage(args, context, project)
        # Fetch MAX_LISTED+1 to detect overflow without a separate COUNT(*).
        caps = ProjectCapability.where(project_id: project.id,
                                       organisation_id: context.organisation.id)
                                .order(:name)
                                .limit(MAX_LISTED + 1)
                                .to_a

        listed = caps.first(MAX_LISTED)
        if listed.empty?
          return Result.new(content: with_code_project(context, project, 'No capabilities have been indexed for this project yet.'),
                            citations: [], kind: :empty, coverage: coverage)
        end

        Result.new(content: with_code_project(context, project, format_list(listed, more: caps.size > MAX_LISTED)),
                   citations: [], coverage: coverage)
      end

      def self.format_list(listed, more:)
        body = listed.map { |c| "- #{c.name}" }.join("\n")
        return body unless more

        "#{body}\n... and more (only first #{MAX_LISTED} shown). " \
          'Use get_capability_details or search_code_symbols to drill in.'
      end
      private_class_method :format_list
    end
  end
end
