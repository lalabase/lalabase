# frozen_string_literal: true

require 'rails_helper'

# Mirrors the jobs.ai_chat locale-parity guard for the persona and answer-style
# VIEW strings. The persona-picker labels, the style-pill labels and the
# regenerate action are user-facing and must exist in DE AND EN. The component
# render tests only exercise the DE labels, so without this a missing EN label
# would ship silently — exactly the drift class ai_chat_keys_spec guards for jobs.*.
RSpec.describe 'chat persona/style view locale parity' do
  shared_keys = %w[persona_label persona_hint]
  message_keys = %w[regenerate regenerating]

  %i[de en].each do |locale|
    # Every step of both style dimensions IS a pill label since 2026-07-19 — a
    # missing level would render an empty pill the user cannot identify.
    ChatStylePreference::DIMENSIONS.each do |dimension|
      it "defines the views.organisations.chats.style_level.dimensions.#{dimension} group label in #{locale}" do
        msg = I18n.t("views.organisations.chats.style_level.dimensions.#{dimension}", locale: locale, fallback: false)
        expect(msg).to be_present
        expect(msg.downcase).not_to include('translation missing')
      end

      ChatStylePreference::LEVELS.each do |level|
        it "defines views.organisations.chats.style_level.#{dimension}.#{level} in #{locale}" do
          msg = I18n.t("views.organisations.chats.style_level.#{dimension}.#{level}", locale: locale, fallback: false)
          expect(msg).to be_present
          expect(msg.downcase).not_to include('translation missing')
        end
      end
    end

    message_keys.each do |key|
      it "defines views.organisations.chats.message.#{key} in #{locale}" do
        msg = I18n.t("views.organisations.chats.message.#{key}", locale: locale, fallback: false)
        expect(msg).to be_present
        expect(msg.downcase).not_to include('translation missing')
      end
    end

    shared_keys.each do |key|
      it "defines views.organisations.chats.shared.#{key} in #{locale}" do
        msg = I18n.t("views.organisations.chats.shared.#{key}", locale: locale, fallback: false)
        expect(msg).to be_present
        expect(msg.downcase).not_to include('translation missing')
      end
    end
  end

  it 'defines the identical style_level key set in DE and EN (no drift)' do
    de = I18n.with_locale(:de) { I18n.t('views.organisations.chats.style_level').keys.sort }
    en = I18n.with_locale(:en) { I18n.t('views.organisations.chats.style_level').keys.sort }
    expect(de).to eq(en)
  end

  # The four one-off pill labels (Kürzer/Ausführlicher/…) and the reset link were
  # removed with the redesign. A leftover leaf in either locale would be dead copy
  # that reads as a live feature.
  it 'defines no leftover pill or reset keys in either locale' do
    %i[de en].each do |locale|
      expect(I18n.exists?('views.organisations.chats.message.pills', locale)).to be(false)
      expect(I18n.exists?('views.organisations.chats.style_level.reset', locale)).to be(false)
      expect(I18n.exists?('views.organisations.chats.style_level.label', locale)).to be(false)
    end
  end
end
