# frozen_string_literal: true

FactoryBot.define do
  factory :admin_ai_credential, class: 'Admin::AiCredential' do
    sequence(:name) { |n| "AI Credential #{n}" }
    provider { 'openai' }
    access_token { 'sk-test-token-1234567890abcdef' }
    default_model { 'gpt-4' }
    active { false }
    enabled { true }

    trait :active do
      active { true }
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
      access_token { 'sk-ant-test-token-1234567890' }
      # Anthropic has no embedding model — purpose 'both' (the column default)
      # would fail the capability validation (AiCredentialProviderRules).
      purpose { 'chat' }
    end

    # Google Vertex AI — mirrors the runtime factory's :google trait
    # (service-account JSON + additional_config routing).
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

    trait :with_organization do
      organization_id { 'org-12345' }
    end

    trait :with_additional_config do
      additional_config { { 'max_tokens' => 4096, 'temperature' => 0.7 } }
    end

    trait :without_token do
      access_token { nil }
    end
  end

  factory :admin_ai_usage, class: 'Admin::AiUsage' do
    organisation_id { create(:organisation).id }
    association :ai_credential, factory: :admin_ai_credential
    provider { 'openai' }
    tokens_used { 1000 }
    cost_cents { 5 }
    model_used { 'gpt-4' }
    used_at { Time.current }

    transient do
      organisation { nil }
    end

    after(:build) do |usage, evaluator|
      usage.organisation_id = evaluator.organisation.id if evaluator.organisation
    end
  end
end
