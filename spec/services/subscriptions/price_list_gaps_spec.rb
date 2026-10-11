# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Subscriptions::PriceListGaps do
  let(:today) { Date.new(2026, 8, 3) }

  def gaps
    described_class.upcoming(from: today)
  end

  context 'with seamless coverage' do
    it 'reports nothing for a single open-ended level' do
      create(:price_list, starts_on: today - 30.days, ends_on: nil)

      expect(gaps).to be_empty
    end

    it 'reports nothing for a level directly followed by its successor' do
      create(:price_list, starts_on: today - 30.days, ends_on: today + 59.days)
      create(:price_list, starts_on: today + 60.days, ends_on: nil)

      expect(gaps).to be_empty
    end
  end

  context 'with no price level at all' do
    it 'reports one never-closing gap starting today' do
      expect(gaps).to eq([{ from: today, to: nil }])
    end
  end

  context 'when the current level ends without a successor' do
    # The classic aftermath of a withdrawn announcement: everything looks fine
    # today, and on day 31 the public pricing page loses its amount.
    it 'reports a gap starting the day after it ends' do
      create(:price_list, starts_on: today - 30.days, ends_on: today + 30.days)

      expect(gaps).to eq([{ from: today + 31.days, to: nil }])
    end
  end

  context 'with a hole between two levels' do
    it 'reports the hole with both boundaries' do
      create(:price_list, starts_on: today - 30.days, ends_on: today + 10.days)
      create(:price_list, starts_on: today + 20.days, ends_on: nil)

      expect(gaps).to eq([{ from: today + 11.days, to: today + 19.days }])
    end
  end

  context 'when today itself is uncovered' do
    it 'reports a gap up to the announced start' do
      create(:price_list, starts_on: today + 60.days, ends_on: nil)

      expect(gaps).to eq([{ from: today, to: today + 59.days }])
    end
  end

  describe 'levels that already expired' do
    it 'ignores them instead of letting them pull the cursor backwards' do
      create(:price_list, starts_on: today - 90.days, ends_on: today - 60.days)
      create(:price_list, starts_on: today - 30.days, ends_on: nil)

      expect(gaps).to be_empty
    end
  end

  # There is no .any? -- it had no production caller and was dropped rather than
  # kept alive by its own spec. Callers ask `upcoming(...).any?` themselves.
  describe 'emptiness as the coverage signal' do
    it 'is empty with seamless coverage' do
      create(:price_list, starts_on: today, ends_on: nil)

      expect(described_class.upcoming(from: today)).to be_empty
    end

    it 'is non-empty with a gap' do
      expect(described_class.upcoming(from: today)).not_to be_empty
    end
  end
end
