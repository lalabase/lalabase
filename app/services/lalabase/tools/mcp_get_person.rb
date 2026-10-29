# frozen_string_literal: true

module Lalabase
  module Tools
    # get_person on /api/mcp (People S3b): the assistant's card (GetPerson.read over
    # People::Lookup) for an agent over a Personal Access Token, with the organisation named
    # (organisation_id, required, E3). Never the notes: they go out on the REST card only (E2).
    # Token-scoped and without citations, like McpFindPeople.
    class McpGetPerson < GetPerson
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
        with_token_lookup(args, context) { |people| read(people, symbolized(args), cite: false) }
      end

      # On this surface a record that is not there is an empty answer, as get_ticket gives one
      # (kind empty); not_found names an organisation the token does not reach. Unknown, foreign
      # and invisible ids answer alike, word for word.
      def self.not_found(raw)
        Result.new(content: not_found_text(raw), kind: :empty)
      end
      private_class_method :not_found
    end
  end
end
