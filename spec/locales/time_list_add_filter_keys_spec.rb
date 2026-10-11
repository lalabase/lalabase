# frozen_string_literal: true

require 'rails_helper'

# The words of "+ Filter" and of the pills it adds (steps 1 and 2 of
# doc/zeiten_weitere_filter_plan.md). Pinned in BOTH languages with
# `fallback: false`: config/initializers/i18n.rb sets fallbacks = [:de], so an
# English page with a missing key renders German, and no request spec notices
# because none of them switches locale. Same pattern as
# time_overview_panel_keys_spec next door.
RSpec.describe 'time list "+ Filter" locale parity' do
  index = 'views.organisations.time_sessions.index'
  empty_reason = 'views.organisations.time_sessions.empty_reason'

  # One heading per kind the menu can offer (_add_filter builds the key from
  # the kind) and one "all" entry per kind's pill.
  keys = ["#{index}.filter_add", "#{empty_reason}.person", "#{index}.filter_ticket_phase_notice",
          "#{index}.filter_ticket_status_heading"] +
         %w[person tag ticket_phase].map { |kind| "#{index}.filter_add_#{kind}" } +
         %w[people tags ticket_phases].map { |plural| "#{index}.filter_all_#{plural}" }

  %i[de en].each do |locale|
    keys.each do |key|
      it "defines #{key} in #{locale}" do
        text = I18n.t(key, locale: locale, fallback: false, default: nil)

        expect(text).to be_present, "#{key} is missing in #{locale}"
      end
    end
  end
end
