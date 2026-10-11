# frozen_string_literal: true

require 'rails_helper'

# The one table of the date presets (doc/filter_datumsvorgaben_rundlauf_plan.md):
# its keys are the bar's quick-filter AND the rule operators of the two date
# fields, its ranges are what both lists filter by.
RSpec.describe SmartFolders::DatePresets do
  include ActiveSupport::Testing::TimeHelpers

  it 'lists the six presets in the order the bar shows them' do
    expect(described_class::KEYS).to eq(%w[today yesterday last_7_days last_30_days this_week this_month])
  end

  it 'is the valueless operator list of created_at and updated_at' do
    expect(SmartFolderRule.field_config['created_at'][:operators]).to include(*described_class::KEYS)
    expect(SmartFolderRule.field_config['updated_at'][:operators]).to include(*described_class::KEYS)
    expect(SmartFolderRule.optional_value_operators).to include(*described_class::KEYS)
  end

  it 'has a label for every preset in both locales, on both surfaces' do
    described_class::KEYS.each do |preset|
      %i[de en].each do |locale|
        expect(I18n.t("smart_folders.operators.#{preset}", locale: locale, raise: true)).to be_present
        expect(I18n.t("views.organisations.tickets.index.date_preset_#{preset}", locale: locale, raise: true)).to be_present
      end
    end
  end

  describe '.range' do
    # 2026-09-09 is a Wednesday; the week starts on Monday 09-07, the month on 09-01.
    around { |example| travel_to(Time.zone.local(2026, 9, 9, 15, 30)) { example.run } }

    it 'this_week starts on Monday at midnight and ends at the end of today' do
      range = described_class.range('this_week')
      expect(range.begin).to eq(Time.zone.local(2026, 9, 7, 0, 0))
      expect(range.end).to eq(Time.zone.local(2026, 9, 9).end_of_day)
    end

    it 'today covers the day, yesterday the day before, neither the other' do
      expect(described_class.range('today')).to cover(Time.zone.local(2026, 9, 9, 0, 0))
      expect(described_class.range('today')).not_to cover(Time.zone.local(2026, 9, 8, 23, 59, 59))
      expect(described_class.range('yesterday')).to cover(Time.zone.local(2026, 9, 8, 23, 59, 59))
      expect(described_class.range('yesterday')).not_to cover(Time.zone.local(2026, 9, 9, 0, 0))
    end

    it 'this_month starts on the first, last_7_days and last_30_days at the beginning of a day' do
      expect(described_class.range('this_month').begin).to eq(Time.zone.local(2026, 9, 1, 0, 0))
      expect(described_class.range('last_7_days').begin).to eq(Time.zone.local(2026, 9, 2, 0, 0))
      expect(described_class.range('last_30_days').begin).to eq(Time.zone.local(2026, 8, 10, 0, 0))
    end

    it 'answers nil for a key it does not know' do
      expect(described_class.range('fancy')).to be_nil
      expect(described_class.valid?('fancy')).to be(false)
      expect(described_class.valid?('this_week')).to be(true)
    end
  end
end
