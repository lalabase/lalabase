# frozen_string_literal: true

module Lalabase
  # Single source of truth for the languages Lalabase's chat + indexing flow
  # supports. Centralised here (not per-class) so the supported set, the
  # fallback, and the coercion rule can't drift between LanguageDetector and the
  # LLM generators — adding (say) French later touches exactly one file. The
  # per-class SUPPORTED_LANGUAGES/DEFAULT_LANGUAGE constants alias these so their
  # "locked as contract" specs and call sites keep working.
  module Languages
    SUPPORTED = %w[de en].freeze
    DEFAULT   = 'en'

    module_function

    # Maps any input to a supported language, falling back to DEFAULT for
    # anything not in SUPPORTED (nil, "", "fr", …).
    def coerce(language)
      SUPPORTED.include?(language.to_s) ? language.to_s : DEFAULT
    end
  end
end
