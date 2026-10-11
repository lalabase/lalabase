# frozen_string_literal: true

# == Schema Information
#
# Table name: embedding_spaces
#
#  id                 :uuid             not null, primary key
#  access_token       :text
#  api_base           :string
#  embedding_dims     :integer          not null
#  embedding_model    :string           not null
#  embedding_provider :string           not null
#  retired_at         :datetime
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  ai_credential_id   :uuid
#  organisation_id    :uuid             not null
#  organization_id    :string
#
# Indexes
#
#  idx_embedding_spaces_unique_triple          (organisation_id,embedding_provider,embedding_model,embedding_dims) UNIQUE
#  index_embedding_spaces_on_ai_credential_id  (ai_credential_id)
#
# Foreign Keys
#
#  fk_rails_...  (ai_credential_id => ai_credentials.id) ON DELETE => nullify
#  fk_rails_...  (organisation_id => organisations.id) ON DELETE => cascade
#
FactoryBot.define do
  # A vector space an org holds (embedding v2 PR 6a). Defaults to the SYSTEM path
  # (all credential columns nil = "resolve the system AiCredential"), because that is
  # the common case; :byok gives it its own snapshot.
  factory :embedding_space do
    association :organisation
    embedding_provider { 'openai' }
    embedding_model    { 'text-embedding-3-small' }
    embedding_dims     { 1536 }

    # A space with its OWN credentials — the case review blocker B2 exists for: after
    # the org's single-valued embedding_* columns have been overwritten, only this
    # snapshot can still serve or roll back this space.
    trait :byok do
      embedding_provider { 'openai_compatible' }
      embedding_model    { 'bge-1536' }
      api_base           { 'https://vectors.example.test/v1' }
      access_token       { 'sk-space-byok' }
    end
  end
end
