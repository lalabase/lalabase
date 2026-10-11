# frozen_string_literal: true

require 'rails_helper'

# Locale-parity guard for the Prompt-Personas v2 management UI (operator backend
# + the shared per-language fields). Test env does NOT raise on missing
# translations, so a typo'd or one-locale-only key would render "translation
# missing" silently in the admin UI. This pins DE/EN parity AND presence for
# every leaf under the persona-management subtrees — the same drift class
# ai_chat_keys_spec / chat_persona_view_keys_spec guard elsewhere.
RSpec.describe 'prompt-personas admin locale parity' do
  subtrees = %w[
    views.admin.prompt_personas
    views.organisations.prompt_personas
    views.prompt_personas.locale_fields
    flash.admin.prompt_personas
    flash.prompt_personas
  ]

  def flatten_keys(hash, prefix = '')
    hash.flat_map do |key, value|
      path = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
      value.is_a?(Hash) ? flatten_keys(value, path) : path
    end
  end

  subtrees.each do |root|
    it "has an identical key structure in DE and EN under #{root}" do
      de = I18n.with_locale(:de) { flatten_keys(I18n.t(root)).sort }
      en = I18n.with_locale(:en) { flatten_keys(I18n.t(root)).sort }
      expect(de).to eq(en)
    end

    %i[de en].each do |locale|
      it "resolves every #{root} leaf in #{locale} (no missing translation)" do
        leaves = I18n.with_locale(locale) { flatten_keys(I18n.t(root)) }
        leaves.each do |leaf|
          msg = I18n.t("#{root}.#{leaf}", locale: locale, fallback: false)
          expect(msg).to be_present, "#{root}.#{leaf} missing in #{locale}"
          expect(msg.to_s.downcase).not_to include('translation missing')
        end
      end
    end
  end

  # Single keys (not subtrees): the admin nav label + the in-app settings tab label.
  ['views.admin.navigation.prompt_personas', 'settings.chat_personas'].each do |key|
    %i[de en].each do |locale|
      it "defines #{key} in #{locale}" do
        msg = I18n.t(key, locale: locale, fallback: false)
        expect(msg).to be_present
        expect(msg.to_s.downcase).not_to include('translation missing')
      end
    end
  end
end
