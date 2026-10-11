# frozen_string_literal: true

FactoryBot.define do
  factory :ai_credential_contract do
    ai_credential
    training_usage { AiCredentialContract::TRAINING_UNSPECIFIED }
    retention_policy { AiCredentialContract::RETENTION_UNSPECIFIED }
    subprocessors_disclosure { AiCredentialContract::SUBPROCESSORS_UNSPECIFIED }
    starts_on { Date.current }
    ends_on { nil }
  end
end
