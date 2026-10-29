# frozen_string_literal: true

require 'rails_helper'

# Guard: every refusal of a token write rule is worded on both surfaces, in
# both locales. Since REST R6 and R3a a rule names its refusals once
# (TimeSessions::Booking::REFUSALS, Posts::Comment::REFUSALS) and each hull
# words them: the MCP tool in its REFUSAL_TEXT, the HTTP API under a
# `services.*` scope in de and en.
#
# Why this exists (the drift it prevents): the three lists are kept by hand.
# A refusal added to a rule without its MCP text raises KeyError in the tool;
# without its locale key the API answers "Translation missing". The request
# specs could not see either while they read the expected text through the
# same key, and with the en->de fallback a key missing in English answers the
# German text on both sides.
#
# Reads the loaded backend rather than `I18n.exists?`, which that fallback
# answers with true for a key that exists only in German.
RSpec.describe 'Token write rule refusal texts' do
  # A new rule with refusals of its own adds a line here.
  rules = [
    { rule: Posts::Comment, tool: Lalabase::Tools::PostComment, scope: %i[services post_comment] },
    { rule: TimeSessions::Booking, tool: Lalabase::Tools::CreateTimeSession, scope: %i[services time_session_booking] }
  ].freeze

  # nil when absent, never the fallback value of another locale.
  def stored(locale, *path)
    I18n.backend.send(:translations)[locale]&.dig(*path)
  end

  before { I18n.backend.send(:init_translations) unless I18n.backend.initialized? }

  rules.each do |entry|
    refusals = entry[:rule]::REFUSALS

    it "words every refusal of #{entry[:rule]} in #{entry[:tool]}, and no other" do
      expect(entry[:tool]::REFUSAL_TEXT.keys).to match_array(refusals)
    end

    %i[de en].each do |locale|
      it "has a #{locale} text for every refusal of #{entry[:rule]}, and no other" do
        texts = stored(locale, *entry[:scope]) || {}
        expect(texts.keys).to match_array(refusals)
        expect(texts.values).to all(be_present)
      end
    end
  end
end
