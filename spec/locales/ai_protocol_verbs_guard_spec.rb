# frozen_string_literal: true

# What: The AI protocol's verb list and the texts that render it
#   (doc/ki_bereich_navigation_plan.md S5, L13/E5).
# Type: Locale guard — runs in the CI guard list via spec/locales/.
# Why (philosophy): The protocol page has two ways to go quietly wrong, and NEITHER
#   produces an error, a blank or anything a reviewer would notice on the rendered page:
#
#     1. A verb the page does not know. AiProtocolActions::ALL is the filter of the
#        query, so a fifth verb — S7 brings one — that lands only at its write site
#        makes the corresponding rows vanish from a trail whose entire value is that it
#        has no holes. Nothing looks broken; there is simply one fewer row.
#     2. A verb the page knows but has no text for. Activity#action_text humanises an
#        unknown key ("Ai Byok Changed") and Activity#message RESCUES
#        I18n::MissingInterpolationArgument into "Actor — Verb". A missing translation
#        therefore renders as plausible copy rather than as "translation missing".
#
#   So the guard pins agreement between two things that both have to move anyway, in
#   opposite directions: the list the reader filters on, and the display texts the
#   writer has to add for its rows to say anything.
# Contract: the `ai_*` verbs under activities.organisation are EXACTLY
#   AiProtocolActions::ALL, in both locales, and each has a short and a long form in
#   both locales.

require 'rails_helper'

RSpec.describe 'AI protocol verbs and their activity texts' do
  # ⚠️ The raw backend tree, not I18n.exists? / I18n.t. This app falls back en→de, so
  # both of those answer "yes" for a key that exists only in German — the exact gap this
  # spec is here to find (MEMORY: "i18n-Guards fallback-fest").
  def translations_for(locale)
    I18n.backend.load_translations
    I18n.backend.translations.fetch(locale, {})
  end

  %i[de en].each do |locale|
    describe "in #{locale}" do
      # Set equality in BOTH directions. "Every verb has a text" alone would pass while
      # the page filtered on three of four verbs; "every text has a verb" alone would
      # pass on a page that displays nothing.
      it 'lists exactly the verbs the protocol page filters on' do
        keys = translations_for(locale).dig(:activities, :organisation).to_h.keys
                                       .map(&:to_s).grep(/\Aai_/).sort

        expect(keys).to eq(AiProtocolActions::ALL.sort)
      end

      AiProtocolActions::ALL.each do |verb|
        it "renders #{verb} with a short form (Activity#action_text)" do
          text = translations_for(locale).dig(:activities, :organisation, verb.to_sym)

          expect(text).to be_present
        end

        # The long form is the sentence the page shows. It has to interpolate the actor,
        # because "wer" is the half of the record that the timestamp does not carry —
        # and #message swallows a missing interpolation argument, so a template that
        # forgot %{actor} would degrade instead of failing.
        it "renders #{verb} with a long form naming the actor (Activity#message)" do
          text = translations_for(locale).dig(:activities, :messages, :organisation, verb.to_sym)

          expect(text).to be_present
          # Regex rather than a literal: the literal form of an i18n placeholder is
          # itself a format-string token and RuboCop rewrites it.
          expect(text).to match(/%\{actor\}/)
        end
      end
    end
  end

  # ⚠️ The list is only "the one owner" if the WRITE sites agree with it, and the guard
  # above compares it against locale keys, not against them. A typo at a write site would
  # produce audit rows the page never shows, and nothing would go red — the trail would
  # be silently incomplete, which is the one failure this whole chapter exists to avoid.
  # Two of the four write sites hold their verb as a constant, so those can be pinned
  # directly. This is also the CLAUDE.md signal "dieselbe Regel zum dritten Mal von Hand":
  # until the write sites read AiProtocolActions themselves, this is what enforces it.
  describe 'the write sites' do
    it 'agrees with the on/off switch' do
      expect(Organisations::AiSettingsController::ACTIVITY_ACTIVATED).to eq(AiProtocolActions::ACTIVATED)
      expect(Organisations::AiSettingsController::ACTIVITY_DEACTIVATED).to eq(AiProtocolActions::DEACTIVATED)
    end

    # The package side now reads the constants instead of holding literals. It was left
    # out at first "because another slice might be touching that file in parallel" — a
    # reason that did not survive checking: none of S4, S6 or S7 goes near
    # select_ai_package.rb. The two verbs it writes are the ones a reader of this page
    # most wants to find, so they are the last two that should have stayed unpinned.
    it 'agrees with the package and tier choice' do
      source = Rails.root.join('app/services/actors/select_ai_package.rb').read

      expect(source).to include('AiProtocolActions::PACKAGE_SELECTED')
      expect(source).to include('AiProtocolActions::TIER_SELECTED')
      expect(source).not_to match(/'ai_(package|tier)_selected'/)
    end
  end

  # The jurisdiction labels are the other half of a protocol row, and they are read with
  # a dynamic key and no default:. A missing one renders a translation_missing span
  # rather than raising, because config.i18n.raise_on_missing_translations is commented
  # out in config/environments/test.rb — so nothing else would catch it.
  describe 'the jurisdiction labels the protocol row interpolates' do
    %i[de en].each do |locale|
      (AiPackage::JURISDICTIONS + ['blank']).each do |key|
        it "renders #{key} in #{locale}" do
          label = translations_for(locale).dig(:views, :organisations, :ai_settings, :packages,
                                               :jurisdictions, key.to_sym)

          expect(label).to be_present
        end
      end
    end
  end
end
