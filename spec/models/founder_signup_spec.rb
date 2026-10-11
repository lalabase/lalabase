# frozen_string_literal: true

# == Schema Information
#
# Table name: founder_signups
#
#  id                   :uuid             not null, primary key
#  company_name         :string           not null
#  company_seat         :string           not null
#  decided_at           :datetime
#  decided_by_email     :string
#  founded_on           :date             not null
#  marketing_consent    :boolean          default(FALSE), not null
#  marketing_consent_at :datetime
#  note                 :text
#  phone                :string           not null
#  previous_tools       :text
#  revenue_band         :string           not null
#  status               :string           default("open"), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  account_id           :uuid             not null
#
# Indexes
#
#  index_founder_signups_on_account_id             (account_id) UNIQUE
#  index_founder_signups_on_status_and_created_at  (status,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
require 'rails_helper'

RSpec.describe FounderSignup do
  describe 'validations' do
    it 'is valid with the declared attributes' do
      expect(build(:founder_signup)).to be_valid
    end

    FounderSignup::DECLARED_ATTRIBUTES.each do |attribute|
      it "requires #{attribute}" do
        signup = build(:founder_signup, attribute => nil)

        expect(signup).not_to be_valid
        expect(signup.errors[attribute]).to be_present
      end
    end

    # The bands are the ONLY thing the form offers; anything else means the
    # request bypassed the form. Guarded because a free string would silently
    # produce an untranslatable value in the operator mail and the admin list.
    it 'rejects a revenue band outside the registry' do
      signup = build(:founder_signup, revenue_band: 'somewhere_between')

      expect(signup).not_to be_valid
      expect(signup.errors[:revenue_band]).to be_present
    end

    it 'accepts every band the form offers' do
      FounderSignup::REVENUE_BANDS.each do |band|
        expect(build(:founder_signup, revenue_band: band)).to be_valid, "band #{band} was rejected"
      end
    end

    it 'rejects a status outside the registry' do
      expect(build(:founder_signup, status: 'pondering')).not_to be_valid
    end

    # A future founding date is a typo, and the value later carries a
    # money-relevant decision.
    it 'rejects a founding date in the future' do
      signup = build(:founder_signup, founded_on: Date.tomorrow)

      expect(signup).not_to be_valid
      expect(signup.errors[:founded_on]).to be_present
    end

    it 'accepts a company founded today' do
      expect(build(:founder_signup, founded_on: Date.current)).to be_valid
    end

    # One request per account -- the DB index enforces it, and so must the model,
    # or the second save raises instead of failing validation.
    it 'allows only one request per account' do
      account = create(:account)
      create(:founder_signup, account: account)

      expect(build(:founder_signup, account: account)).not_to be_valid
    end

    it 'allows requests for two different accounts' do
      create(:founder_signup, account: create(:account))

      expect(build(:founder_signup, account: create(:account))).to be_valid
    end
  end

  describe 'defaults' do
    it 'starts open and without consent' do
      signup = described_class.new

      expect(signup.status).to eq(FounderSignup::STATUS_OPEN)
      expect(signup.marketing_consent).to be(false)
    end
  end

  describe '#open? / #decided?' do
    it 'is open while undecided' do
      signup = build(:founder_signup)

      expect(signup).to be_open
      expect(signup).not_to be_decided
    end

    it 'is decided once granted' do
      signup = build(:founder_signup, :granted)

      expect(signup).not_to be_open
      expect(signup).to be_decided
    end

    it 'is decided once declined' do
      expect(build(:founder_signup, :declined)).to be_decided
    end
  end

  describe '.open_requests' do
    it 'returns only open ones, newest first' do
      older = create(:founder_signup, account: create(:account), created_at: 2.days.ago)
      newer = create(:founder_signup, account: create(:account), created_at: 1.hour.ago)
      create(:founder_signup, :granted, account: create(:account))

      expect(described_class.open_requests).to eq([newer, older])
    end
  end

  describe 'account association' do
    # § 12.3.4: the record IS the evaluation table -- a declined request that
    # disappeared would take half the statistics with it. Only deleting the
    # account removes it.
    it 'survives being declined' do
      signup = create(:founder_signup, :declined)

      expect(described_class.find(signup.id)).to be_present
    end

    it 'is destroyed with its account' do
      signup = create(:founder_signup)

      expect { signup.account.destroy }.to change(described_class, :count).by(-1)
    end
  end
end
