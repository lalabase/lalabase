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
  end

  # =========================================================================
  # Instance Methods
  # =========================================================================
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
end
