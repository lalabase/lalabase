# frozen_string_literal: true

# == Schema Information
#
# Table name: ai_credentials
#
#  id                          :uuid             not null, primary key
#  access_token                :text             not null
#  active                      :boolean          default(FALSE)
#  additional_config           :json
#  api_base                    :string
#  company_domicile            :string
#  default_model               :string
#  description                 :text
#  display_name                :string
#  embedding_cost_per_1m_cents :integer
#  enabled                     :boolean          default(TRUE)
#  included_in_quota           :boolean          default(FALSE), not null
#  input_cost_per_1m_cents     :integer
#  name                        :string           not null
#  output_cost_per_1m_cents    :integer
#  provider                    :string           default("openai"), not null
#  purpose                     :string           default("both"), not null
#  region                      :string
#  created_at                  :datetime         not null
#  updated_at                  :datetime         not null
#  organization_id             :string
#
# Indexes
#
#  index_ai_credentials_on_active               (active)
#  index_ai_credentials_on_enabled              (enabled)
#  index_ai_credentials_on_provider             (provider)
#  index_ai_credentials_on_provider_and_active  (provider,active) UNIQUE WHERE (active = true)
#
FactoryBot.define do
  factory :ai_credential do
    sequence(:name) { |n| "AI Credential #{n}" }
    provider { 'openai' }
    access_token { 'sk-test-token-1234567890abcdef' }
    default_model { 'gpt-4' }
    active { false }
    enabled { true }
    # Quota credentials must carry prices (model guard); default to a valid,
    # priced system credential. Use :not_metered or :without_prices to opt out.
    purpose { 'both' }
    included_in_quota { true }
    input_cost_per_1m_cents { 15 }
    output_cost_per_1m_cents { 60 }
    embedding_cost_per_1m_cents { 2 }

    trait :active do
      active { true }
    end

    # Not billed against a quota (e.g. a BYOK-mirroring test credential); the
    # price guard does not apply, so prices may be blank.
    trait :not_metered do
      included_in_quota { false }
      input_cost_per_1m_cents { nil }
      output_cost_per_1m_cents { nil }
      embedding_cost_per_1m_cents { nil }
    end

    # A metered credential missing its prices — invalid; used by the guard spec.
    trait :without_prices do
      included_in_quota { true }
      input_cost_per_1m_cents { nil }
      output_cost_per_1m_cents { nil }
      embedding_cost_per_1m_cents { nil }
    end

    trait :chat_only do
      purpose { 'chat' }
      embedding_cost_per_1m_cents { nil }
    end

    trait :embedding_only do
      purpose { 'embedding' }
      input_cost_per_1m_cents { nil }
      output_cost_per_1m_cents { nil }
    end

    trait :disabled do
      enabled { false }
    end

    trait :active_disabled do
      active { true }
      enabled { false }
    end

    trait :anthropic do
      provider { 'anthropic' }
      default_model { 'claude-3-opus' }
      access_token { "sk-ant-#{'a' * 95}" }
      # Anthropic has no embedding model — purpose 'both' would fail the
      # capability validation (AiCredentialProviderRules).
      purpose { 'chat' }
    end

    # Google Vertex AI (implemented since the GoogleVertexProvider slice):
    # service-account JSON in the encrypted access_token, regional routing in
    # additional_config — mirrors what the provider's fail-fast checks expect.
    trait :google do
      provider { 'google' }
      default_model { 'gemini-2.0-flash' }
      access_token do
        { type: 'service_account', project_id: 'lala-eu',
          private_key: "-----BEGIN PRIVATE KEY-----\nMIItest\n-----END PRIVATE KEY-----\n",
          client_email: 'vertex@lala-eu.iam.gserviceaccount.com' }.to_json
      end
      additional_config { { 'project_id' => 'lala-eu', 'location' => 'europe-west3' } }
    end

    # The rail the three EU presets run on (§4.1): endpoint in the api_base
    # COLUMN, not in the legacy additional_config['uri_base'] — several rows of
    # this shape under ONE provider name is the case packages address by id for.
    trait :openai_compatible do
      provider { 'openai_compatible' }
      api_base { 'https://api.mistral.ai/v1' }
      default_model { 'mistral-small-latest' }
      access_token { 'eu-endpoint-token-1234567890' }
      region { 'eu' }
    end

    # E12: the company-seat axis. Stated separately from :region on purpose —
    # they are two independent facts, and a package claim is judged against both.
    trait :eu_company do
      company_domicile { 'eu' }
    end

    trait :non_eu_company do
      company_domicile { 'non_eu' }
    end

    trait :with_organization do
      organization_id { 'org-12345' }
    end

    trait :with_description do
      description { 'Test credential description' }
    end

    trait :with_additional_config do
      additional_config { { 'max_tokens' => 4096, 'temperature' => 0.7 } }
    end
  end
end
