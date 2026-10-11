# frozen_string_literal: true

# == Schema Information
#
# Table name: ai_package_tiers
#
#  id                 :uuid             not null, primary key
#  chat_model         :string
#  key                :string           not null
#  label              :string           not null
#  position           :integer          default(0), not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  ai_package_id      :uuid             not null
#  chat_credential_id :uuid
#
# Indexes
#
#  idx_ai_package_tiers_unique_key_per_package   (ai_package_id,key) UNIQUE
#  index_ai_package_tiers_on_chat_credential_id  (chat_credential_id)
#
# Foreign Keys
#
#  fk_rails_...  (ai_package_id => ai_packages.id)
#  fk_rails_...  (chat_credential_id => ai_credentials.id)
#
require 'rails_helper'

# What this file protects (doc/ki_pakete_plan.md §6, §7b.1, E2/E9)
# ----------------------------------------------------------------
# 1. A rung without a usable chat credential is a package that fails at the
#    first customer question. The select offers only enabled, chat-purposed
#    credentials; these validations catch manipulation and the race where a
#    credential is disabled between rendering and submitting the form.
# 2. NO provider coupling to the package's embedding slot (§9 Falle 2) — the
#    anthropic case below is the normal case, not an exotic one.
# 3. #effective_chat_model is the single place the tier override beats the
#    credential default, and the Vertex probe (E9) must judge exactly that
#    model: probing the credential default while the tier runs an override
#    would check the wrong thing and report "fine" for a broken package.
#
# Validation checks assert errors.details (not message strings) so they are
# locale-independent and pin the error TYPE rather than its wording.
RSpec.describe AiPackageTier do
  def vertex_matrix(region:, model:, status_code:)
    {
      checked_at: Time.current, project_id: 'lala-eu', regions: [region], models: [model],
      results: [{ region: region, model: model, status_code: status_code,
                  available: status_code == 200, info_only: false }]
    }
  end

  def stub_probe(matrix)
    allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:cached).and_return(matrix)
  end

  def error_types(record, attribute)
    record.validate
    record.errors.details[attribute].map { |detail| detail[:error] }
  end

  describe 'key' do
    it 'accepts both rungs of the E2 ladder' do
      described_class::KEYS.each do |key|
        tier = build(:ai_package_tier, key: key, label: described_class::DEFAULT_LABELS.fetch(key))

        expect(tier).to be_valid, "expected key #{key} to be valid"
      end
    end

    it 'rejects a key outside KEYS — the two rungs are a product decision (E2)' do
      expect(error_types(build(:ai_package_tier, key: 'premium'), :key)).to include(:inclusion)
    end

    it 'rejects a second tier with the same key in one package (mirrors the unique index)' do
      package = create(:ai_package)
      create(:ai_package_tier, ai_package: package, key: 'fast')

      expect(error_types(build(:ai_package_tier, ai_package: package, key: 'fast'), :key)).to include(:taken)
    end

    it 'allows the same key in a different package — the key is unique per package, not globally' do
      create(:ai_package_tier, ai_package: create(:ai_package), key: 'fast')

      expect(build(:ai_package_tier, ai_package: create(:ai_package), key: 'fast')).to be_valid
    end
  end

  describe 'label' do
    it 'requires a label — it is the rung name the customer picks from' do
      expect(error_types(build(:ai_package_tier, label: nil), :label)).to include(:blank)
    end
  end

  describe 'chat credential' do
    it 'requires a credential' do
      expect(error_types(build(:ai_package_tier, chat_credential: nil), :chat_credential)).to include(:blank)
    end

    it 'accepts a chat-purposed credential' do
      expect(build(:ai_package_tier, chat_credential: create(:ai_credential, :chat_only, region: 'eu'))).to be_valid
    end

    it 'accepts a dual-purpose credential — "both" covers chat' do
      expect(build(:ai_package_tier, chat_credential: create(:ai_credential))).to be_valid
    end

    it 'rejects a disabled credential' do
      tier = build(:ai_package_tier, chat_credential: create(:ai_credential, :disabled, region: 'eu'))

      expect(error_types(tier, :chat_credential)).to include(:disabled)
    end

    it 'rejects an embedding-only credential — its purpose excludes chat' do
      tier = build(:ai_package_tier, chat_credential: create(:ai_credential, :embedding_only, region: 'eu'))

      expect(error_types(tier, :chat_credential)).to include(:wrong_purpose)
    end

    # §9 Falle 2 from the tier side: nothing here may look at the package's
    # embedding provider. Anthropic cannot embed at all, and it is precisely the
    # provider the flagship package puts on its rungs.
    it 'accepts an anthropic credential regardless of the package embedding provider' do
      package = create(:ai_package, embedding_credential: create(:ai_credential, :embedding_only, region: 'eu'))
      tier = build(:ai_package_tier, ai_package: package, chat_credential: create(:ai_credential, :anthropic, region: 'eu'))

      expect(tier).to be_valid
    end
  end

  describe '#effective_chat_model' do
    it 'prefers the tier override over the credential default (§6.1)' do
      tier = build(:ai_package_tier, chat_model: 'claude-sonnet-4',
                                     chat_credential: create(:ai_credential, default_model: 'gpt-4'))

      expect(tier.effective_chat_model).to eq('claude-sonnet-4')
    end

    it 'falls back to the credential default when no override is set' do
      tier = build(:ai_package_tier, chat_model: nil,
                                     chat_credential: create(:ai_credential, default_model: 'gpt-4'))

      expect(tier.effective_chat_model).to eq('gpt-4')
    end

    it 'treats a blank override as no override' do
      tier = build(:ai_package_tier, chat_model: '',
                                     chat_credential: create(:ai_credential, default_model: 'gpt-4'))

      expect(tier.effective_chat_model).to eq('gpt-4')
    end
  end

  describe 'Vertex model availability (E9, §9 Falle 3)' do
    # default_model and additional_config['location'] of the :google trait.
    let(:google_credential) { create(:ai_credential, :google) }
    let(:region) { 'europe-west3' }

    it 'blocks the save on a clear 404 for the credential default model' do
      stub_probe(vertex_matrix(region: region, model: 'gemini-2.0-flash', status_code: 404))
      tier = build(:ai_package_tier, chat_credential: google_credential)

      expect(error_types(tier, :chat_model)).to include(:vertex_model_unavailable)
      expect(tier.errors[:chat_model].join).to include('gemini-2.0-flash').and include(region)
    end

    # The override is what actually runs, so it is what has to be judged — a
    # probe against the credential default would clear a broken package.
    it 'judges the tier override, not the credential default' do
      stub_probe(vertex_matrix(region: region, model: 'gemini-2.5-pro', status_code: 404))
      tier = build(:ai_package_tier, chat_credential: google_credential, chat_model: 'gemini-2.5-pro')

      expect(error_types(tier, :chat_model)).to include(:vertex_model_unavailable)
    end

    it 'clears an override the probe reports as available, even when the default is dead' do
      stub_probe({ checked_at: Time.current, project_id: 'lala-eu', regions: [region],
                   models: %w[gemini-2.5-pro gemini-2.0-flash],
                   results: [{ region: region, model: 'gemini-2.5-pro', status_code: 200,
                               available: true, info_only: false },
                             { region: region, model: 'gemini-2.0-flash', status_code: 404,
                               available: false, info_only: false }] })
      tier = build(:ai_package_tier, chat_credential: google_credential, chat_model: 'gemini-2.5-pro')

      expect(tier).to be_valid
    end

    it 'saves through a transport failure — an outage must not block maintenance' do
      stub_probe(vertex_matrix(region: region, model: 'gemini-2.0-flash', status_code: nil))

      expect(build(:ai_package_tier, chat_credential: google_credential)).to be_valid
    end

    it 'saves when the probe itself raises' do
      allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:cached)
        .and_raise(Lalabase::Llm::VertexAvailabilityProbe::ProbeError, 'no service account')

      expect(build(:ai_package_tier, chat_credential: google_credential)).to be_valid
    end

    it 'never probes for a non-google credential' do
      expect(Lalabase::Llm::VertexAvailabilityProbe).not_to receive(:cached)

      build(:ai_package_tier).validate
    end

    it 'does not probe again when neither credential nor model changed' do
      stub_probe(nil)
      tier = create(:ai_package_tier, chat_credential: google_credential)

      expect(Lalabase::Llm::VertexAvailabilityProbe).not_to receive(:cached)
      tier.update!(label: 'Umbenannt')
    end
  end

  describe 'error messages' do
    it 'ships every custom message in both locales' do
      keys = %w[
        chat_credential.disabled
        chat_credential.wrong_purpose
        chat_model.vertex_model_unavailable
      ].map { |key| "activerecord.errors.models.ai_package_tier.attributes.#{key}" }

      %i[de en].each do |locale|
        keys.each do |key|
          expect(I18n.exists?(key, locale)).to be(true), "missing translation #{key} (#{locale})"
        end
      end
    end
  end
end
