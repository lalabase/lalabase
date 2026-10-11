# frozen_string_literal: true

require 'json'

module Lalabase
  module Indexer
    # Asks the LLM to produce Layer-3: a list of named capabilities of the project
    # ("Notification System", "Multi-Tenancy", "Chat Streaming", ...). Each
    # capability gets a one-paragraph description. The LLM is asked to respond in
    # strict JSON so we can persist directly.
    #
    # Returns an array of {name:, description:, key_modules: []}. key_modules is
    # filled later (M6) once we have CodeSymbol IDs to attach.
    class CapabilityGenerator
      class ParseError < StandardError; end

      MAX_TOKENS = 1500
      TEMPERATURE = 0.2
      MAX_CAPABILITIES = 25
      MIN_CAPABILITIES = 3
      MAX_NAME_LENGTH = 100
      MAX_DESCRIPTION_LENGTH = 2_000
      # Aliases of Lalabase::Languages (kept for the contract specs); coercion lives there.
      DEFAULT_LANGUAGE = Lalabase::Languages::DEFAULT
      SUPPORTED_LANGUAGES = Lalabase::Languages::SUPPORTED

      def initialize(provider:, scan:, language: nil)
        @provider = provider
        @scan = scan
        @language = Lalabase::Languages.coerce(language)
      end

      # @return [Hash] {capabilities: [{name:, description:, key_modules: []}],
      #                 language:, model_used:, token_usage:}
      def call
        result = @provider.chat(
          messages: [
            { role: 'system', content: system_prompt },
            { role: 'user',   content: user_prompt }
          ],
          max_tokens: MAX_TOKENS,
          temperature: TEMPERATURE
        )
        {
          capabilities: parse_capabilities!(result[:content]),
          language: @language,
          model_used: result[:model_used],
          token_usage: result[:token_usage]
        }
      end

      private

      def system_prompt
        intro = case @language
                when 'de'
                  'Liste die Capabilities (fachliche Funktionsbausteine) dieses Projekts auf — ' \
                  'keine Klassen-Namen, sondern Geschäftsfunktionen wie "Benachrichtigungs-System", ' \
                  '"Multi-Tenancy", "Such-Engine". Pro Capability ein 1–2-Satz-description.'
                else
                  'List the capabilities (functional building blocks) of this project — not class ' \
                  'names, but business functions like "Notification System", "Multi-Tenancy", ' \
                  '"Search Engine". One short description per capability.'
                end
        intro + ' Respond with strict JSON, no commentary, exactly this shape: ' \
          '{"capabilities": [{"name": "...", "description": "..."}]}. ' \
          "Between #{MIN_CAPABILITIES} and #{MAX_CAPABILITIES} entries."
      end

      def user_prompt
        parts = ScanPrompt.doc_sections(@scan)
        parts << "## Top-level directories\n\n#{@scan[:top_level].join("\n")}" if @scan[:top_level]&.any?
        ScanPrompt.join_or(parts, 'No metadata available — respond with an empty capabilities array.')
      end

      def parse_capabilities!(raw)
        json_text = extract_json(raw.to_s)
        parsed = JSON.parse(json_text)
        items  = parsed.is_a?(Hash) ? parsed['capabilities'] : parsed
        raise ParseError, "expected array of capabilities, got #{items.class}" unless items.is_a?(Array)

        items.filter_map { |item| coerce_capability(item) }.first(MAX_CAPABILITIES)
      rescue JSON::ParserError => e
        raise ParseError, "LLM returned invalid JSON: #{e.message}"
      end

      # Strip any ```json fences or surrounding prose the LLM might emit despite instructions.
      def extract_json(text)
        if text =~ /```(?:json)?\s*(.+?)```/m
          Regexp.last_match(1).strip
        else
          text.strip
        end
      end

      def coerce_capability(item)
        return nil unless item.is_a?(Hash)

        name = item['name'].to_s.strip[0, MAX_NAME_LENGTH].to_s
        description = item['description'].to_s.strip[0, MAX_DESCRIPTION_LENGTH].to_s
        return nil if name.empty? || description.empty?

        { name: name, description: description, key_modules: [] }
      end
    end
  end
end
