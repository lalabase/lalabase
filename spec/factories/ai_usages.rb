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
FactoryBot.define do
  factory :ai_usage do
    association :organisation
    association :ai_credential
    provider { 'openai' }
    tokens_used { 1000 }
    cost_cents { 5 }
    model_used { 'gpt-4' }
    used_at { Time.current }
  end
end
