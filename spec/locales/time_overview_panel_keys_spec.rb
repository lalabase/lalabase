# frozen_string_literal: true

require 'rails_helper'

# The status table's own sentences (S5b): the fold trigger and the two empty
# states. Pinned in BOTH languages with `fallback: false`, because
# config/initializers/i18n.rb sets fallbacks = [:de]: an English page with a
# missing key renders German and no request spec notices, since none of them
# switches locale. Same pattern as time_list_billing_words_spec next door.
RSpec.describe 'time list status table locale parity' do
  scope = 'views.organisations.time_sessions.billing_overview_panel'

  %i[de en].each do |locale|
    %w[no_data empty_period_reset col_project col_total total_row].each do |key|
      it "defines #{scope}.#{key} in #{locale}" do
        text = I18n.t("#{scope}.#{key}", locale: locale, fallback: false)

        expect(text).to be_present
        expect(text.downcase).not_to include('translation missing')
      end
    end

    # The two sentences that carry a period name have to leave room for it.
    %w[footnote empty_period].each do |key|
      it "keeps the period placeholder in #{scope}.#{key} in #{locale}" do
        text = I18n.t("#{scope}.#{key}", locale: locale, fallback: false, period: 'PERIODE')

        expect(text).to include('PERIODE')
        expect(text.downcase).not_to include('translation missing')
      end
    end

    it "defines both plural forms of #{scope}.reveal_empty_projects in #{locale}" do
      [1, 2].each do |count|
        text = I18n.t("#{scope}.reveal_empty_projects", locale: locale, count: count, fallback: false)

        expect(text).to include(count.to_s)
        expect(text.downcase).not_to include('translation missing')
      end
    end
  end
end
