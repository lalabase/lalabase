# frozen_string_literal: true

module Lalabase
  module Tools
    # find_people on /api/mcp (People S3b), for an agent such as Claude Code over a Personal
    # Access Token: the assistant's rows, search and limit (FindPeople.list over People::Lookup),
    # in a class of its own because the schema differs. It names the organisation
    # (organisation_id, required, E3), which the assistant takes from its thread.
    #
    # Token-scoped: the directory is the organisation's, not a project's, so no project gate
    # runs and PeopleTool.with_token_lookup decides instead (E1, tenant, people right,
    # authorization mark). No citations: there is no chat reader to gate on this surface.
    #
    # A flat name, not Tools::Mcp::FindPeople: a module Mcp inside Lalabase::Tools would hide
    # ::Mcp (Dispatcher, ToolCall) from every file in this namespace.
    class McpFindPeople < FindPeople
      def self.scope_mode
        :token
      end

      def self.authorization_mode
        :record
      end

      def self.description
        "#{super} #{TOKEN_NOTE}"
      end

      def self.input_schema
        with_organisation_id(super)
      end

      def self.execute(args:, context:)
        with_token_lookup(args, context) { |people| list(people, symbolized(args), cite: false) }
      end
    end
  end
end
