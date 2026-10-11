# frozen_string_literal: true

# == Schema Information
#
# Table name: ai_usages
#
#  id               :uuid             not null, primary key
#  action           :string
#  cost_cents       :decimal(12, 6)   default(0.0)
#  credits_used     :integer          default(0), not null
#  metadata         :json
#  model_used       :string
#  provider         :string           not null
#  subject_type     :string
#  tokens_used      :integer          default(0)
#  used_at          :datetime
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  ai_credential_id :uuid
#  organisation_id  :uuid             not null
#  subject_id       :uuid
#  user_id          :uuid
#
# Indexes
#
#  index_ai_usages_on_ai_credential_id             (ai_credential_id)
#  index_ai_usages_on_organisation_id              (organisation_id)
#  index_ai_usages_on_organisation_id_and_used_at  (organisation_id,used_at)
#  index_ai_usages_on_provider_and_used_at         (provider,used_at)
#  index_ai_usages_on_subject_type_and_subject_id  (subject_type,subject_id)
#  index_ai_usages_on_user_id                      (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (ai_credential_id => ai_credentials.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id) ON DELETE => nullify
#
require 'rails_helper'

RSpec.describe Admin::AiUsage, type: :model do
  let(:organisation) { create(:organisation) }

  def create_ai_usage(attrs = {})
    defaults = {
      organisation_id: organisation.id,
      provider: 'openai',
      tokens_used: 100,
      cost_cents: 50,
      used_at: Time.current,
      model_used: 'gpt-4'
    }
    described_class.create!(defaults.merge(attrs))
  end

  # =========================================================================
  # Table & Model Configuration
  # =========================================================================
  describe 'table configuration' do
    it 'uses the ai_usages table' do
      expect(described_class.table_name).to eq('ai_usages')
    end

    it 'strips Admin namespace from model_name for routing' do
      expect(described_class.model_name.to_s).to eq('AiUsage')
    end

    it 'uses Admin::Organisation association instead of tenant-scoped Organisation' do
      org_assoc = described_class.reflect_on_association(:organisation)
      expect(org_assoc.options[:class_name]).to eq('Admin::Organisation')
    end
  end

  # =========================================================================
  # Associations
  # =========================================================================
  describe 'associations' do
    it { is_expected.to belong_to(:organisation).class_name('Admin::Organisation') }
    it { is_expected.to belong_to(:ai_credential).class_name('Admin::AiCredential').optional }
  end

  # =========================================================================
  # Scopes
  # =========================================================================
  describe 'scopes' do
    describe '.recent' do
      let!(:old_usage) { create_ai_usage(used_at: 31.days.ago) }
      let!(:recent_usage) { create_ai_usage(used_at: 1.day.ago) }
      let!(:today_usage) { create_ai_usage(used_at: Time.current) }

      it 'returns records from the last 30 days by default' do
        results = described_class.recent.to_a
        expect(results).to include(recent_usage, today_usage)
        expect(results).not_to include(old_usage)
      end

      it 'accepts a custom number of days' do
        results = described_class.recent(7)
        expect(results).to include(today_usage)
        expect(results).not_to include(old_usage)
      end

      it 'returns nothing when all records are older than the period' do
        results = described_class.recent(0)
        expect(results).to be_empty
      end
    end

    describe '.by_provider' do
      let!(:openai_usage) { create_ai_usage(provider: 'openai') }
      let!(:anthropic_usage) { create_ai_usage(provider: 'anthropic') }

      it 'filters by provider' do
        expect(described_class.by_provider('openai')).to contain_exactly(openai_usage)
      end

      it 'returns empty for unknown provider' do
        expect(described_class.by_provider('nonexistent')).to be_empty
      end
    end

    describe '.ordered_by_date' do
      let!(:older) { create_ai_usage(used_at: 2.days.ago) }
      let!(:newer) { create_ai_usage(used_at: 1.day.ago) }

      it 'orders by used_at descending' do
        expect(described_class.ordered_by_date.to_a).to eq([newer, older])
      end
    end

    describe '.ordered_by_usage' do
      let!(:low) { create_ai_usage(tokens_used: 10) }
      let!(:high) { create_ai_usage(tokens_used: 1000) }

      it 'orders by tokens_used descending' do
        expect(described_class.ordered_by_usage.to_a).to eq([high, low])
      end
    end

    describe '.ordered_by_cost' do
      let!(:cheap) { create_ai_usage(cost_cents: 5) }
      let!(:expensive) { create_ai_usage(cost_cents: 500) }

      it 'orders by cost_cents descending' do
        expect(described_class.ordered_by_cost.to_a).to eq([expensive, cheap])
      end
    end
  end

  # =========================================================================
  # Instance Methods
  # =========================================================================
  describe '#organisation_name' do
    it 'returns the organisation name' do
      usage = create_ai_usage
      expect(usage.organisation_name).to eq(organisation.name)
    end

    it 'returns nil when organisation is missing (dangling FK)' do
      build(:organisation).tap { |o| o.save!(validate: false) }
      ai_usage = described_class.new(organisation: nil)
      expect(ai_usage.organisation_name).to be_nil
    end
  end

  describe '#ai_credential_name' do
    it 'returns credential name when credential exists' do
      credential = Admin::AiCredential.create!(
        # default_model became mandatory on this model with #391 (an active
        # credential without a model dies at the provider); this fixture predated that.
        name: 'Test Cred', provider: 'openai', access_token: 'sk-test123',
        default_model: 'gpt-4o-mini'
      )
      usage = create_ai_usage(ai_credential_id: credential.id)
      expect(usage.ai_credential_name).to eq('Test Cred')
    end

    it 'returns fallback when no credential is set' do
      usage = create_ai_usage(ai_credential_id: nil)
      expect(usage.ai_credential_name).to eq('System-Credentials')
    end
  end

  describe '#provider_display' do
    it 'capitalizes the provider name' do
      usage = create_ai_usage(provider: 'openai')
      expect(usage.provider_display).to eq('Openai')
    end

    it 'handles nil provider gracefully' do
      usage = described_class.new(provider: nil)
      expect(usage.provider_display).to be_a(String)
    end
  end

  describe '#cost_in_euros' do
    it 'converts cents to euros' do
      usage = create_ai_usage(cost_cents: 150)
      expect(usage.cost_in_euros).to eq(1.50)
    end

    it 'returns 0.0 for zero cost' do
      usage = create_ai_usage(cost_cents: 0)
      expect(usage.cost_in_euros).to eq(0.0)
    end

    it 'handles small amounts correctly (no integer division)' do
      usage = create_ai_usage(cost_cents: 1)
      expect(usage.cost_in_euros).to eq(0.01)
    end
  end

  describe '#usage_date' do
    it 'formats the date in German format' do
      usage = create_ai_usage(used_at: Time.zone.local(2025, 12, 31, 14, 30))
      expect(usage.usage_date).to eq('31.12.2025 14:30')
    end

    it 'returns a fallback when used_at is nil' do
      usage = described_class.new(used_at: nil)
      expect(usage.usage_date).to be_a(String)
    end
  end

  describe '#model_display' do
    it 'returns the model name when present' do
      usage = create_ai_usage(model_used: 'gpt-4')
      expect(usage.model_display).to eq('gpt-4')
    end

    it 'returns fallback for nil model_used' do
      usage = create_ai_usage(model_used: nil)
      expect(usage.model_display).to eq('Unbekanntes Model')
    end

    it 'returns fallback for blank model_used' do
      usage = create_ai_usage(model_used: '')
      expect(usage.model_display).to eq('Unbekanntes Model')
    end
  end

  describe '#tokens_formatted' do
    it 'formats small numbers without separator' do
      usage = create_ai_usage(tokens_used: 100)
      expect(usage.tokens_formatted).to eq('100')
    end

    it 'adds comma separators for thousands' do
      usage = create_ai_usage(tokens_used: 1_234_567)
      expect(usage.tokens_formatted).to eq('1,234,567')
    end

    it 'handles zero' do
      usage = create_ai_usage(tokens_used: 0)
      expect(usage.tokens_formatted).to eq('0')
    end
  end

  describe '#cost_formatted' do
    it 'formats cost in euros with symbol' do
      usage = create_ai_usage(cost_cents: 1234)
      expect(usage.cost_formatted).to eq('€ 12.34')
    end

    it 'formats zero cost' do
      usage = create_ai_usage(cost_cents: 0)
      expect(usage.cost_formatted).to eq('€ 0.00')
    end
  end

  describe '#provider_css_class' do
    it 'returns green classes for openai' do
      usage = create_ai_usage(provider: 'openai')
      expect(usage.provider_css_class).to include('green')
    end

    it 'returns blue classes for anthropic' do
      usage = create_ai_usage(provider: 'anthropic')
      expect(usage.provider_css_class).to include('blue')
    end

    it 'returns blue classes for claude' do
      usage = create_ai_usage(provider: 'claude')
      expect(usage.provider_css_class).to include('blue')
    end

    it 'returns yellow classes for google' do
      usage = create_ai_usage(provider: 'google')
      expect(usage.provider_css_class).to include('yellow')
    end

    it 'returns gray classes for unknown providers' do
      usage = create_ai_usage(provider: 'some_new_provider')
      expect(usage.provider_css_class).to include('gray')
    end

    it 'handles nil provider gracefully' do
      usage = described_class.new(provider: nil)
      expect(usage.provider_css_class).to be_a(String)
    end
  end

  describe '#usage_summary' do
    it 'returns a complete summary hash' do
      usage = create_ai_usage(
        provider: 'openai',
        model_used: 'gpt-4',
        tokens_used: 500,
        cost_cents: 100
      )
      summary = usage.usage_summary

      expect(summary).to include(
        organisation: organisation.name,
        provider: 'Openai',
        model: 'gpt-4',
        tokens: 500,
        cost_cents: 100,
        cost_euros: 1.0,
        credential: 'System-Credentials'
      )
      expect(summary[:date]).to be_a(String)
    end
  end

  # =========================================================================
  # Class Methods (Statistics)
  # =========================================================================
  describe '.total_tokens_for_period' do
    before do
      create_ai_usage(tokens_used: 100, used_at: 1.day.ago)
      create_ai_usage(tokens_used: 200, used_at: 2.days.ago)
      create_ai_usage(tokens_used: 999, used_at: 60.days.ago)
    end

    it 'sums tokens for the default 30-day period' do
      expect(described_class.total_tokens_for_period).to eq(300)
    end

    it 'sums tokens for a custom period' do
      expect(described_class.total_tokens_for_period(90)).to eq(1299)
    end

    it 'returns 0 when no records exist in the period' do
      expect(described_class.total_tokens_for_period(0)).to eq(0)
    end
  end

  describe '.total_cost_for_period' do
    before do
      create_ai_usage(cost_cents: 50, used_at: 1.day.ago)
      create_ai_usage(cost_cents: 75, used_at: 2.days.ago)
    end

    it 'sums cost_cents for the period' do
      expect(described_class.total_cost_for_period).to eq(125)
    end

    it 'returns 0 when no records exist' do
      expect(described_class.total_cost_for_period(0)).to eq(0)
    end
  end

  describe '.average_tokens_per_request' do
    it 'calculates the average tokens per request' do
      create_ai_usage(tokens_used: 100, used_at: 1.day.ago)
      create_ai_usage(tokens_used: 200, used_at: 2.days.ago)
      expect(described_class.average_tokens_per_request).to eq(150)
    end

    it 'returns 0 when there are no records' do
      expect(described_class.average_tokens_per_request).to eq(0)
    end

    it 'handles a single record' do
      create_ai_usage(tokens_used: 42, used_at: 1.day.ago)
      expect(described_class.average_tokens_per_request).to eq(42)
    end
  end

  describe '.usage_by_provider' do
    before do
      create_ai_usage(provider: 'openai', tokens_used: 100, used_at: 1.day.ago)
      create_ai_usage(provider: 'openai', tokens_used: 200, used_at: 2.days.ago)
      create_ai_usage(provider: 'anthropic', tokens_used: 50, used_at: 1.day.ago)
    end

    it 'groups token usage by provider' do
      result = described_class.usage_by_provider
      expect(result['openai']).to eq(300)
      expect(result['anthropic']).to eq(50)
    end

    it 'returns empty hash when no records exist' do
      described_class.delete_all
      expect(described_class.usage_by_provider).to be_empty
    end
  end

  describe '.cost_by_provider' do
    before do
      create_ai_usage(provider: 'openai', cost_cents: 100, used_at: 1.day.ago)
      create_ai_usage(provider: 'anthropic', cost_cents: 50, used_at: 1.day.ago)
    end

    it 'groups cost by provider' do
      result = described_class.cost_by_provider
      expect(result['openai']).to eq(100)
      expect(result['anthropic']).to eq(50)
    end
  end

  describe '.usage_by_organisation' do
    let(:org2) { create(:organisation, name: 'Other Org') }

    before do
      create_ai_usage(tokens_used: 100, used_at: 1.day.ago)
      create_ai_usage(tokens_used: 200, used_at: 1.day.ago, organisation_id: org2.id)
    end

    it 'groups tokens by organisation name' do
      result = described_class.usage_by_organisation
      expect(result[organisation.name]).to eq(100)
      expect(result['Other Org']).to eq(200)
    end
  end

  describe '.top_consuming_organisations' do
    let(:org2) { create(:organisation, name: 'Heavy User Org') }

    before do
      create_ai_usage(tokens_used: 100, used_at: 1.day.ago)
      create_ai_usage(tokens_used: 5000, used_at: 1.day.ago, organisation_id: org2.id)
    end

    it 'returns organisations sorted by token usage descending' do
      result = described_class.top_consuming_organisations
      expect(result.first[0]).to eq('Heavy User Org')
      expect(result.first[1]).to eq(5000)
    end

    it 'respects the limit parameter' do
      result = described_class.top_consuming_organisations(1)
      expect(result.size).to eq(1)
    end

    it 'returns empty array when no records exist' do
      described_class.delete_all
      expect(described_class.top_consuming_organisations).to be_empty
    end
  end
end
