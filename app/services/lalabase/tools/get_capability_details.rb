# frozen_string_literal: true

module Lalabase
  module Tools
    # Fetches full details of a single project capability by UUID, including
    # its description and the key_modules array (file/class references that
    # make up this capability).
    #
    # The project-id where-clause is defense-in-depth on top of the implicit
    # acts_as_tenant scope: even if the LLM hallucinates a UUID belonging to
    # another project of the same org, the find_by returns nil → "not found".
    class GetCapabilityDetails < Base
      MAX_DESCRIPTION_LEN = 2000

      # Its reach is a rights question (Base.resolve_code_project) -- see
      # GetProjectVision for the whole reason.
      def self.requires_actor?
        true
      end

      def self.tool_name
        'get_capability_details'
      end

      def self.description
        'Fetches full details of a single project capability by UUID, ' \
          'including its description and key_modules (file/class references). ' \
          'Use after list_capabilities or when a capability ID appears in ' \
          'the baseline context and you want to drill in. A capability belongs ' \
          'to ONE project; in an org-wide assistant thread the id must come from ' \
          'a list_capabilities call for that same project.'
      end

      def self.input_schema
        {
          type: 'object',
          properties: {
            capability_id: { type: 'string', description: 'UUID of the capability' }
          }.merge(PROJECT_FILTER_SCHEMA),
          required: ['capability_id']
        }
      end

      def self.execute(args:, context:)
        args = symbolized(args)
        capability_id = args[:capability_id].to_s.strip
        return Result.invalid_input('capability_id is required') if capability_id.empty?

        # Before the format check on purpose: a missing project is the more
        # actionable error, and the order is pinned by a spec.
        project = resolve_code_project(args, context)
        return project if project.is_a?(Result)
        return Result.invalid_input('invalid capability_id format') unless capability_id.match?(UUID_FORMAT)

        coverage = code_coverage(args, context, project)
        cap = ProjectCapability.where(project_id: project.id,
                                      organisation_id: context.organisation.id)
                               .find_by(id: capability_id)
        # "Not found" is an empty success, not a tool failure — same convention
        # as GetSymbolDetails and ListCapabilities. Reserves Result#error for
        # genuine failures (missing context, invalid input format, DB errors).
        if cap.nil?
          return Result.new(content: with_code_project(context, project, "No capability found for #{capability_id}."),
                            citations: [], kind: :empty, coverage: coverage)
        end

        Result.new(
          content: with_code_project(context, project, format_capability(cap)),
          citations: [Lalabase::Citations.capability(cap)],
          coverage: coverage
        )
      end

      def self.format_capability(cap)
        desc = cap.description.to_s[0, MAX_DESCRIPTION_LEN]
        modules = cap.key_modules.is_a?(Array) ? cap.key_modules : []
        modules_section = modules.empty? ? '' : "\n\n**Key modules:**\n#{modules.map { |m| "- #{m}" }.join("\n")}"
        "## #{cap.name}\n\n#{desc}#{modules_section}"
      end
      private_class_method :format_capability
    end
  end
end
