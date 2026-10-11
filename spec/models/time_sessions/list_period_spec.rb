# frozen_string_literal: true

require 'rails_helper'

# What: The vocabulary of periods the time area offers -- the eight preset keys,
#       their order, their labels, their windows, and the two ways the list and
#       the status table differ (default, and whether `custom` is on offer).
# Why:  Before S5 the keys were a literal array in _filter_pills, the labels
#       eight t() calls beside it, and the key -> window mapping a `case` in the
#       controller. The table needs the same vocabulary, and a second copy of a
#       window is how a clicked cell comes to mean a different fortnight than
#       the list it opens.
RSpec.describe TimeSessions::ListPeriod do
  include ActiveSupport::Testing::TimeHelpers

  describe 'the vocabulary' do
    it 'offers the eight presets in display order' do
      expect(described_class::KEYS).to eq(
        %w[this_week this_month this_quarter last_10_days 30_days 90_days year all]
      )
    end

    it 'keeps `custom` out of the presets and inside the list keys' do
      expect(described_class::KEYS).not_to include('custom')
      expect(described_class::LIST_KEYS).to eq(described_class::KEYS + ['custom'])
    end

    # `fallback: false` is the whole point. config/initializers/i18n.rb sets
    # `fallbacks = [:de]`, so a missing EN key answers with the GERMAN string:
    # present, no marker, and the English segmented control silently reads
    # "Letzte 90 Tage". Asserting be_present here proves nothing, and neither
    # does looking for "translation missing" -- I18n writes "Translation
    # missing:" with a capital T (i18n exceptions.rb), so a lowercase check
    # matches nothing, ever, even when the key is gone from both locales.
    #
    # Mutation probe: delete filter_range_90_days from zeiterfassung.en.yml.
    it 'has its OWN entry in both locales, not the German one through the fallback' do
      described_class::LIST_KEYS.each do |key|
        %i[de en].each do |locale|
          own = I18n.t(described_class.label_key(key), locale: locale, fallback: false, default: nil)
          expect(own).to be_present, "#{locale} has no own label for #{key}, only the fallback"
        end
      end
    end

    # One spot check in words, because "an entry exists" and "the entry is
    # English" are different questions and only this one catches a DE block
    # pasted into the EN file.
    it 'says the English words in English' do
      I18n.with_locale(:en) do
        expect(described_class.label('90_days')).to eq('last 90 days')
        expect(described_class.label('all')).to eq('all time')
        expect(described_class.label('custom')).to eq('custom range')
      end
    end

    it 'hands options out as [key, label] pairs in KEYS order' do
      expect(described_class.options.map(&:first)).to eq(described_class::KEYS)
      expect(described_class.options.first.last).to eq(described_class.label('this_week'))
    end
  end

  describe '.normalize_for_list' do
    it 'passes every list key through untouched' do
      described_class::LIST_KEYS.each do |key|
        expect(described_class.normalize_for_list(key)).to eq(key)
      end
    end

    it 'answers the list default for anything else' do
      ['', nil, 'garbage', 'THIS_WEEK', ['this_week'], 'table_default'].each do |junk|
        expect(described_class.normalize_for_list(junk)).to eq('this_month')
      end
    end

    it 'accepts a symbol as its string' do
      expect(described_class.normalize_for_list(:this_week)).to eq('this_week')
    end
  end

  describe '.normalize_for_table' do
    it 'passes every preset through untouched' do
      described_class::KEYS.each do |key|
        expect(described_class.normalize_for_table(key)).to eq(key)
      end
    end

    # The table has no two date fields, so `custom` there would be a period with
    # no window: it must fall back like any other unknown value, not through.
    it 'does not offer custom, and answers the table default for it' do
      expect(described_class.normalize_for_table('custom')).to eq('all')
    end

    it 'answers the table default for anything else' do
      ['', nil, 'garbage'].each do |junk|
        expect(described_class.normalize_for_table(junk)).to eq('all')
      end
    end
  end

  describe 'the two defaults' do
    it 'differ on purpose: the list narrows to this month, the table shows everything' do
      expect(described_class::LIST_DEFAULT).to eq('this_month')
      expect(described_class::TABLE_DEFAULT).to eq('all')
      expect(described_class.normalize_for_list(nil)).not_to eq(described_class.normalize_for_table(nil))
    end
  end

  describe '.bounds_for' do
    let(:today) { Date.new(2026, 5, 20) } # a Wednesday

    it 'answers no window for `all`' do
      expect(described_class.bounds_for('all', today: today)).to eq([nil, nil])
    end

    it 'answers no window for `custom`, whose bounds come from the date fields' do
      expect(described_class.bounds_for('custom', today: today)).to eq([nil, nil])
    end

    # ⚠️ These two windows are 31 and 91 days long, today included -- unlike
    # `last_10_days`, which Overview::TimePeriod resolves as `now - 9.days` and
    # so is 10 days long. Bestand, moved here unchanged from the controller's
    # `case`; named because the eight presets now sit in one list and the row
    # therefore offers two readings of "letzte N Tage". Changing it would move
    # every existing answer by a day, so it is a product call, not a cleanup.
    it 'counts 30 and 90 days back from today, today included' do
      expect(described_class.bounds_for('30_days', today: today)).to eq([Date.new(2026, 4, 20), today])
      expect(described_class.bounds_for('90_days', today: today)).to eq([Date.new(2026, 2, 19), today])
    end

    it 'spans the whole calendar year for `year`' do
      expect(described_class.bounds_for('year', today: today)).to eq([Date.new(2026, 1, 1), Date.new(2026, 12, 31)])
    end

    it 'returns a start not after the end for every preset' do
      described_class::KEYS.each do |key|
        start_date, end_date = described_class.bounds_for(key, today: today)
        next if start_date.nil?

        expect(start_date).to be <= end_date, "#{key} spans backwards"
      end
    end

    # NO travel_to on purpose. `today:` used to reach only the four keys this
    # class computes itself; the four delegated to Overview::TimePeriod answered
    # from the wall clock, so the same argument meant something for half the
    # vocabulary and nothing for the other half. The example above walks all
    # eight with `today:` and cannot see it: start <= end holds for the real
    # current week just as well.
    #
    # 2026-05-20 is a Wednesday, so its week runs Mon 18th to Sun 24th.
    it 'honours an explicit today for the delegated keys too' do
      expect(described_class.bounds_for('this_week', today: today))
        .to eq([Date.new(2026, 5, 18), Date.new(2026, 5, 24)])
      expect(described_class.bounds_for('this_month', today: today))
        .to eq([Date.new(2026, 5, 1), Date.new(2026, 5, 31)])
      expect(described_class.bounds_for('this_quarter', today: today))
        .to eq([Date.new(2026, 4, 1), Date.new(2026, 6, 30)])
      expect(described_class.bounds_for('last_10_days', today: today))
        .to eq([Date.new(2026, 5, 11), today])
    end
  end

  # The reason SHARED_WITH_OVERVIEW exists: a drill-down from a dashboard widget
  # lands in this list, and its figure has to be reproducible there to the day.
  # A second definition of "this week" would break that silently.
  describe 'the windows shared with the dashboard widgets' do
    it 'names exactly the keys both period models know' do
      expect(described_class::SHARED_WITH_OVERVIEW).to eq(%w[this_week this_month this_quarter last_10_days])
      expect(described_class::SHARED_WITH_OVERVIEW).to all(be_in(Overview::TimePeriod::KEYS))
    end

    it 'takes their window from Overview::TimePeriod rather than recomputing it' do
      travel_to Time.zone.local(2026, 5, 20, 14, 0) do
        described_class::SHARED_WITH_OVERVIEW.each do |key|
          resolved = Overview::TimePeriod.range_for(key)
          expect(described_class.bounds_for(key)).to eq([resolved.start_at.to_date, resolved.end_at.to_date]),
                                                     "#{key} drifted from the widget window"
        end
      end
    end
  end
end
