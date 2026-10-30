# frozen_string_literal: true

require 'rails_helper'

# Guard: every refusal of a token write rule is worded on both surfaces, in
# both locales. Since REST R6, R3a and R3b a rule names its refusals once
# (TimeSessions::Booking::REFUSALS, Posts::Comment::REFUSALS,
# Tickets::Change::REFUSALS and ::FAILURES) and each hull words them: the MCP
# tool in its REFUSAL_TEXT, the HTTP API under a `services.*` scope in de and en.
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
    { rule: 'Posts::Comment', refusals: Posts::Comment::REFUSALS, texts: Lalabase::Tools::PostComment::REFUSAL_TEXT,
      scope: %i[services post_comment] },
    { rule: 'TimeSessions::Booking', refusals: TimeSessions::Booking::REFUSALS, texts: Lalabase::Tools::CreateTimeSession::REFUSAL_TEXT,
      scope: %i[services time_session_booking] },
    { rule: 'Tickets::Change', refusals: Tickets::Change::REFUSALS, texts: Lalabase::Tools::UpdateTicket::REFUSAL_TEXT,
      scope: %i[services ticket_change] },
    { rule: 'Tickets::Change (failures)', refusals: Tickets::Change::FAILURES, texts: Lalabase::Tools::UpdateTicket::FAILURE_TEXT,
      scope: %i[services ticket_change_failure] }
  ].freeze

  # nil when absent, never the fallback value of another locale.
  def stored(locale, *path)
    I18n.backend.send(:translations)[locale]&.dig(*path)
  end

  before { I18n.backend.send(:init_translations) unless I18n.backend.initialized? }

  rules.each do |entry|
    it "words every refusal of #{entry[:rule]} for MCP, and no other" do
      expect(entry[:texts].keys).to match_array(entry[:refusals])
    end

    %i[de en].each do |locale|
      it "has a #{locale} text for every refusal of #{entry[:rule]}, and no other" do
        texts = stored(locale, *entry[:scope]) || {}
        expect(texts.keys).to match_array(entry[:refusals])
        expect(texts.values).to all(be_present)
      end
    end

    # A placeholder only one language has would raise in the other.
    it "names the same placeholders in both languages for #{entry[:rule]}" do
      placeholders = ->(locale) { (stored(locale, *entry[:scope]) || {}).transform_values { |text| text.scan(/%\{(\w+)\}/).flatten.sort } }
      expect(placeholders.call(:de)).to eq(placeholders.call(:en))
    end
  end
end
