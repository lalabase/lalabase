# frozen_string_literal: true

# == Schema Information
#
# Table name: account_discounts
#
#  id               :uuid             not null, primary key
#  ends_on          :date
#  granted_by_email :string
#  percent_off      :integer          not null
#  reason           :string
#  starts_on        :date             not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :uuid             not null
#
# Indexes
#
#  index_account_discounts_on_account_id_and_starts_on  (account_id,starts_on)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
require 'rails_helper'

RSpec.describe AccountDiscount do
  let(:account) { create(:account) }

  it_behaves_like 'an effectively dated record' do
    let(:expected_scope_columns) { [:account_id] }

    def dated_record(attrs = {})
      build(:account_discount, account: account, **attrs)
    end

    def dated_record!(attrs = {})
      create(:account_discount, account: account, **attrs)
    end
  end

  describe 'exactly one active discount per account (D3)' do
    let(:today) { Date.new(2026, 8, 3) }

    it 'refuses a second discount overlapping the first' do
      create(:account_discount, account: account, starts_on: today, ends_on: today + 6.months)

      second = build(:account_discount, account: account, percent_off: 50,
                                        starts_on: today + 1.month, ends_on: nil)

      expect(second).not_to be_valid
    end

    it 'allows a successor once the first has ended' do
      create(:account_discount, account: account, starts_on: today, ends_on: today + 6.months)

      successor = build(:account_discount, account: account, percent_off: 20,
                                           starts_on: today + 6.months + 1.day, ends_on: nil)

      expect(successor).to be_valid
    end

    # The pre-landing review found that flipping lteq to lt in the overlap query
    # left the whole suite green -- "exactly one active discount" was asserted
    # nowhere at the boundary. These two pin the single-day touch points.
    it 'refuses a successor starting on the predecessor last day' do
      create(:account_discount, account: account, starts_on: today, ends_on: today + 30.days)

      touching = build(:account_discount, account: account, percent_off: 10,
                                          starts_on: today + 30.days, ends_on: nil)

      expect(touching).not_to be_valid
    end

    it 'refuses a predecessor ending on the successor first day' do
      create(:account_discount, account: account, starts_on: today + 30.days, ends_on: nil)

      touching = build(:account_discount, account: account, percent_off: 10,
                                          starts_on: today, ends_on: today + 30.days)

      expect(touching).not_to be_valid
    end

    it 'does not restrict a different account in the same period' do
      other_account = create(:account)
      create(:account_discount, account: account, starts_on: today, ends_on: today + 6.months)

      concurrent = build(:account_discount, account: other_account,
                                            starts_on: today, ends_on: today + 6.months)

      expect(concurrent).to be_valid
    end
  end

  describe 'percent_off bounds' do
    it 'rejects 0 -- a discount that discounts nothing is a data error' do
      expect(build(:account_discount, percent_off: 0)).not_to be_valid
    end

    it 'accepts 1' do
      expect(build(:account_discount, percent_off: 1)).to be_valid
    end

    it 'accepts 100 (a fully waived period)' do
      expect(build(:account_discount, percent_off: 100)).to be_valid
    end

    it 'rejects more than 100' do
      expect(build(:account_discount, percent_off: 101)).not_to be_valid
    end

    it 'rejects a fractional percentage' do
      expect(build(:account_discount, percent_off: 12.5)).not_to be_valid
    end
  end

  describe '#open_ended?' do
    it 'is true without an end date' do
      expect(build(:account_discount, ends_on: nil)).to be_open_ended
    end

    it 'is false with an end date' do
      expect(build(:account_discount, ends_on: Date.current)).not_to be_open_ended
    end
  end

  describe 'lifecycle' do
    it 'is destroyed with its account' do
      create(:account_discount, account: account)

      expect { account.destroy! }.to change(described_class, :count).by(-1)
    end
  end
end
