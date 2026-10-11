# frozen_string_literal: true

require 'rails_helper'

# S3 KI-Kontingent: ai_usages is the universal usage event. These specs pin the
# rollout-safe contract of the new columns:
# - action is a nullable-first whitelist (unknown rejected, nil allowed) so old
#   writers keep working while new writers always set a valid action (test 14/32)
# - credits_used never goes negative
# - the quota_counted scope is what separates "counts against the budget" from
#   "logged for transparency but free" (BYOK / non-metered credential, tests 6/8)
RSpec.describe AiUsage do
  let(:organisation) { create(:organisation) }
  let(:quota_credential) { create(:ai_credential, provider: 'openai', included_in_quota: true) }

  describe 'action validation (nullable-first whitelist)' do
    it 'accepts a known registry action' do
      usage = build(:ai_usage, organisation: organisation, action: 'chat_message')
      expect(usage).to be_valid
    end

    it 'accepts a nil action (old-shape writer during rollout, test 32)' do
      usage = build(:ai_usage, organisation: organisation, action: nil)
      expect(usage).to be_valid
    end

    it 'rejects a non-nil unknown action (test 14)' do
      usage = build(:ai_usage, organisation: organisation, action: 'totally_made_up')
      expect(usage).not_to be_valid
      expect(usage.errors[:action]).to be_present
    end

    # Whitelist positive iteration: a negative-only test survives a registry that
    # dropped an action. Iterate the CONSTANT so shrinking ActionRegistry.keys (or
    # letting the model's inclusion list drift away from it) turns a formerly-valid
    # action red here.
    Lalabase::Llm::ActionRegistry::ACTIONS.each_key do |registry_action|
      it "accepts the registry action #{registry_action.inspect}" do
        expect(build(:ai_usage, organisation: organisation, action: registry_action)).to be_valid
      end
    end
  end

  describe 'credits_used validation' do
    it 'rejects a negative credit count' do
      usage = build(:ai_usage, organisation: organisation, credits_used: -1)
      expect(usage).not_to be_valid
      expect(usage.errors[:credits_used]).to be_present
    end

    # Boundary n: 0 must stay valid. Legacy rows and non-metered logs carry 0, so a
    # mutation of `greater_than_or_equal_to: 0` to `greater_than: 0` would break them.
    it 'accepts a zero credit count (boundary: >= 0, not > 0)' do
      expect(build(:ai_usage, organisation: organisation, credits_used: 0)).to be_valid
    end

    it 'defaults to 0' do
      expect(described_class.new.credits_used).to eq(0)
    end
  end

  # Defense in depth (migration contract): the user FK must NULLIFY, not cascade —
  # a personal-data erasure removes the attribution but MUST keep the org's usage
  # history. Introspects the real DB FK, so flipping the migration to :cascade /
  # :restrict (or dropping on_delete) turns this red.
  describe 'user FK on_delete semantics' do
    it 'declares the users FK with on_delete: nullify' do
      fk = ActiveRecord::Base.connection.foreign_keys('ai_usages').find { |f| f.to_table == 'users' }
      expect(fk).to be_present
      expect(fk.on_delete).to eq(:nullify)
    end
  end

  describe 'polymorphic subject + user' do
    it 'stores an optional user and polymorphic subject' do
      user = create(:user)
      usage = described_class.create!(organisation: organisation, provider: 'openai',
                                      user: user, subject: organisation,
                                      action: 'chat_message', credits_used: 2)
      expect(usage.user).to eq(user)
      expect(usage.subject).to eq(organisation)
      expect(usage.subject_type).to eq('Organisation')
    end

    it 'allows a nil user (system/background jobs, test 13)' do
      usage = described_class.create!(organisation: organisation, provider: 'openai',
                                      user: nil, action: 'document_indexing', credits_used: 1)
      expect(usage.user).to be_nil
    end
  end

  describe '.track_usage' do
    it 'persists the new event fields' do
      user = create(:user)
      usage = described_class.track_usage(
        organisation, 'openai', 1234,
        ai_credential: quota_credential, user: user, subject: organisation,
        action: 'summary', credits_used: 2, cost_cents: 3, model: 'gpt-4o-mini'
      )
      expect(usage).to have_attributes(action: 'summary', credits_used: 2, user_id: user.id,
                                       subject_type: 'Organisation', ai_credential_id: quota_credential.id)
    end

    it 'defaults credits_used to 0 when omitted (old callers)' do
      usage = described_class.track_usage(organisation, 'openai', 10)
      expect(usage.credits_used).to eq(0)
      expect(usage.action).to be_nil
    end
  end

  describe '.quota_counted' do
    it 'includes only rows billed on an included_in_quota system credential' do
      metered = described_class.create!(organisation: organisation, provider: 'openai',
                                        ai_credential: quota_credential, credits_used: 5)
      non_metered_cred = create(:ai_credential, :not_metered, provider: 'openai')
      described_class.create!(organisation: organisation, provider: 'openai',
                              ai_credential: non_metered_cred, credits_used: 5)
      # BYOK: no system credential attributed
      described_class.create!(organisation: organisation, provider: 'openai',
                              ai_credential: nil, credits_used: 5)

      expect(described_class.quota_counted).to contain_exactly(metered)
    end
  end

  describe '.in_month' do
    it 'scopes to the given calendar month' do
      this_month = described_class.create!(organisation: organisation, provider: 'openai',
                                           ai_credential: quota_credential, credits_used: 1,
                                           used_at: Time.current.beginning_of_month + 2.days)
      described_class.create!(organisation: organisation, provider: 'openai',
                              ai_credential: quota_credential, credits_used: 1,
                              used_at: Time.current.beginning_of_month - 1.day)
      expect(described_class.in_month(Time.current)).to contain_exactly(this_month)
    end
  end
end
