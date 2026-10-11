# frozen_string_literal: true

module Lalabase
  module Indexer
    # Asks the LLM to produce Layer-4: a 200–500-word natural-language description
    # of what this project IS — its purpose, the people it serves, the major
    # building blocks. Embedding is computed separately by the job.
    class VisionGenerator
      MAX_TOKENS = 800
      TEMPERATURE = 0.3
      # Aliases of the canonical set in Lalabase::Languages (kept for the
      # "locked as contract" specs + readability); the coercion rule lives there.
      DEFAULT_LANGUAGE = Lalabase::Languages::DEFAULT
      SUPPORTED_LANGUAGES = Lalabase::Languages::SUPPORTED

      def initialize(provider:, scan:, language: nil)
        @provider = provider
        @scan = scan
        @language = Lalabase::Languages.coerce(language)
      end

      # @return [Hash] {content:, language:, model_used:, token_usage:}
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
          content: result[:content].to_s.strip,
          language: @language,
          model_used: result[:model_used],
          token_usage: result[:token_usage]
        }
      end

      private

      def system_prompt
        case @language
        when 'de'
          'Du bist ein Software-Analyst. Schreibe in natürlicher deutscher Sprache eine ' \
          '200–500-Wörter-Beschreibung des Projekts: Was es tut, für wen, welche groben ' \
          'Bausteine es hat. Keine Marketing-Phrasen. Keine Aufzählungen — fließender Text.'
        else
          'You are a software analyst. Write a 200–500-word natural-language description ' \
          'of the project: what it does, who it serves, what its major building blocks are. ' \
          'No marketing language. No bullet lists — flowing prose only.'
        end
      end

      def user_prompt
        parts = ScanPrompt.doc_sections(@scan)
        parts << "## Manifests\n\n#{@scan[:manifests].map { |name, body| "### #{name}\n#{body}" }.join("\n\n")}" if @scan[:manifests]&.any?
        parts << "## Top-level directory\n\n#{@scan[:top_level].join("\n")}" if @scan[:top_level]&.any?
        parts << "Primary language detected: #{@scan[:language_hint]}" if @scan[:language_hint]

        ScanPrompt.join_or(parts, 'No metadata available — describe a generic empty repository.')
      end
    end
  end
end
