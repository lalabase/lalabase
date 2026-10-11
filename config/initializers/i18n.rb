# frozen_string_literal: true

# I18n fallback configuration
# If a key is missing in the current locale, it falls back to :de.
# This way EN mode shows German text instead of "translation missing" errors,
# while the i18n migration is in progress.
Rails.application.config.i18n.fallbacks = [:de]
