# frozen_string_literal: true

# == Schema Information
#
# Table name: price_lists
#
#  id               :uuid             not null, primary key
#  created_by_email :string
#  currency         :string           default("EUR"), not null
#  ends_on          :date
#  note             :string
#  plan_key         :string           not null
#  starts_on        :date             not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
# Indexes
#
#  index_price_lists_on_plan_key_and_starts_on  (plan_key,starts_on)
#
require 'rails_helper'

RSpec.describe PriceList do
  it_behaves_like 'an effectively dated record' do
    let(:expected_scope_columns) { [:plan_key] }

    def dated_record(attrs = {})
      build(:price_list, **attrs)
    end

    def dated_record!(attrs = {})
      create(:price_list, **attrs)
    end
  end

  describe 'validations' do
    it 'rejects an unknown plan key' do
      expect(build(:price_list, plan_key: 'enterprise')).not_to be_valid
    end

    it 'requires a currency' do
      expect(build(:price_list, currency: nil)).not_to be_valid
    end
  end

  describe 'multi-tenancy' do
    # Pricing is operator data, not tenant data, and the PUBLIC pricing page
    # reads it with no tenant set (D7). An accidental acts_as_tenant here would
    # filter every row away without raising anything -- the page would silently
    # show no price forever.
    it 'is readable without a current tenant' do
      list = create(:price_list)

      ActsAsTenant.with_tenant(nil) do
        expect(described_class.find_by(id: list.id)).to eq(list)
      end
    end
  end

  describe 'ladder association' do
    it 'destroys its tiers with it' do
      list = create(:price_list, :with_v4_monthly_ladder)

      expect { list.destroy! }.to change(PriceTier, :count).by(-7)
    end
  end
end
