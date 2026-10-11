# frozen_string_literal: true

require 'rails_helper'

# What: Overview::TimePeriod — the single source of truth for the selectable
#       reporting periods shared by the week widgets and the time-sessions drill-down.
# Why:  The widget figure and the drill-down sum must use the EXACT same inclusive
#       window, so the boundaries (and the unknown-key fallback) are the contract.
RSpec.describe Overview::TimePeriod do
  # Tue 2026-06-23 12:00 UTC — KW 26, Q2. Fixed so the windows are assertable.
  let(:now) { Time.utc(2026, 6, 23, 12, 0, 0) }

  around { |ex| I18n.with_locale(:de) { ex.run } }

  describe '.normalize' do
    it 'passes every known key through unchanged' do
      described_class::KEYS.each { |key| expect(described_class.normalize(key)).to eq(key) }
    end

    it 'accepts symbol input' do
      expect(described_class.normalize(:this_month)).to eq('this_month')
    end

    it 'falls back to DEFAULT for unknown, blank or nil input' do
      [nil, '', 'bogus', 'last_week'].each do |bad|
        expect(described_class.normalize(bad)).to eq(described_class::DEFAULT)
      end
    end
  end

  describe '.range_for' do
    it 'this_week spans Monday 00:00 .. Sunday 23:59:59' do
      r = described_class.range_for('this_week', now: now)
      expect(r.start_at).to eq(Time.utc(2026, 6, 22).beginning_of_day)
      expect(r.end_at).to eq(Time.utc(2026, 6, 28).end_of_day)
      expect(r.subtitle).to eq('KW 26')
    end

    it 'this_month spans the first .. last day of the month' do
      r = described_class.range_for('this_month', now: now)
      expect(r.start_at).to eq(Time.utc(2026, 6, 1).beginning_of_day)
      expect(r.end_at).to eq(Time.utc(2026, 6, 30).end_of_day)
      expect(r.subtitle).to eq('Juni 2026')
    end

    it 'this_quarter spans the whole calendar quarter (Q2 = Apr..Jun)' do
      r = described_class.range_for('this_quarter', now: now)
      expect(r.start_at).to eq(Time.utc(2026, 4, 1).beginning_of_day)
      expect(r.end_at).to eq(Time.utc(2026, 6, 30).end_of_day)
      expect(r.subtitle).to eq('Q2 2026')
    end

    it 'last_10_days spans today and the previous 9 days (10 inclusive)' do
      r = described_class.range_for('last_10_days', now: now)
      expect(r.start_at).to eq(Time.utc(2026, 6, 14).beginning_of_day)
      expect(r.end_at).to eq(Time.utc(2026, 6, 23).end_of_day)
      expect((r.end_at.to_date - r.start_at.to_date).to_i + 1).to eq(10)
    end

    it 'resolves an unknown key to the default window (this_week)' do
      expect(described_class.range_for('bogus', now: now).key).to eq('this_week')
    end

    it 'exposes the matching title key per period' do
      described_class::KEYS.each do |key|
        expect(described_class.range_for(key, now: now).title_key)
          .to eq("dashboard.briefing.period.title.#{key}")
      end
    end
  end
end
