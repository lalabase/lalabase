# frozen_string_literal: true

require 'rails_helper'

# S3 KI-Kontingent: AiQuotaHelper is THE single derivation of the UI state (off /
# within / grace / exhausted) and the 80% pre-warning. Because the bar, the banners
# and the search hint all read it, a mutation here would silently desync the whole
# UI from the gate — so these pin the state mapping and the exact warning boundary.
RSpec.describe AiQuotaHelper, type: :helper do
  # budget 10 + buffer 5 → hard limit 15; 80% of 10 = 8 credits.
  let(:organisation) { create(:organisation, ai_quota_credits_override: 10, ai_quota_buffer_override: 5) }
  let(:credential) { create(:ai_credential, provider: 'openai', included_in_quota: true) }

  def book(credits)
    AiUsage.create!(organisation: organisation, provider: 'openai', ai_credential: credential,
                    credits_used: credits, used_at: Time.current)
  end

  describe '#ai_quota_state' do
    it 'is :off when AI is not enabled (opt-in wins, even with a budget)' do
      expect(helper.ai_quota_state(create(:organisation, :ai_disabled))).to eq(:off)
    end

    it 'is :within under budget' do
      book(5)
      expect(helper.ai_quota_state(organisation)).to eq(:within)
    end

    it 'is :grace at the budget' do
      book(10)
      expect(helper.ai_quota_state(organisation)).to eq(:grace)
    end

    it 'is :exhausted at the hard limit' do
      book(15)
      expect(helper.ai_quota_state(organisation)).to eq(:exhausted)
    end
  end

  describe '#ai_quota_warn? boundary (n-1 / n / over-budget)' do
    it 'is false at 70% (7 credits, n-1)' do
      book(7)
      expect(helper.ai_quota_warn?(organisation.ai_quota_ledger)).to be(false)
    end

    # Boundary n: the warning fires at EXACTLY 80%. Mutation `>= 80` → `> 80` would
    # skip it here.
    it 'is true at exactly 80% (8 credits, n)' do
      book(8)
      expect(helper.ai_quota_warn?(organisation.ai_quota_ledger)).to be(true)
    end

    # Over budget the grace banner owns the messaging, not the pre-warning — this
    # also pins within_budget? flipping AT the budget (a `<` → `<=` mutation would
    # keep the warning firing during grace).
    it 'is false once at/over the budget (grace zone owns the message)' do
      book(10)
      expect(helper.ai_quota_warn?(organisation.ai_quota_ledger)).to be(false)
    end
  end

  describe '#ai_quota_fill_class' do
    it 'maps each state to a distinct colour' do
      expect(helper.ai_quota_fill_class(:exhausted)).to include('red')
      expect(helper.ai_quota_fill_class(:grace)).to include('amber')
      expect(helper.ai_quota_fill_class(:within)).to include('cobalt')
    end
  end
end
