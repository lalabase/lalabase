# frozen_string_literal: true

# == Schema Information
#
# Table name: organisations
#
#  id                        :uuid             not null, primary key
#  ai_access_token           :text
#  ai_activated_at           :datetime
#  ai_api_base               :string
#  ai_connection_checked_at  :datetime
#  ai_connection_status      :string
#  ai_enabled                :boolean          default(FALSE), not null
#  ai_package_selected_at    :datetime
#  ai_package_tier_key       :string
#  ai_provider               :string           default("openai")
#  ai_quota_buffer_override  :integer
#  ai_quota_credits_override :integer
#  data_import_enabled       :boolean          default(FALSE), not null
#  domain                    :string
#  email_subject_prefix      :string
#  embedding_access_token    :text
#  embedding_api_base        :string
#  embedding_dims            :integer
#  embedding_model           :string
#  embedding_provider        :string
#  embedding_retention_limit :integer          default(2), not null
#  name                      :string
#  notification_sender_email :string
#  preferred_chat_model      :string
#  code_indexing_enabled      :boolean          default(FALSE), not null
#  subdomain                 :string
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  account_id                :uuid
#  active_embedding_space_id :uuid
#  ai_activated_by_id        :uuid
#  ai_organization_id        :string
#  ai_package_id             :uuid
#  ai_package_selected_by_id :uuid
#  embedding_organization_id :string
#
# Indexes
#
#  index_organisations_on_account_id                 (account_id)
#  index_organisations_on_ai_activated_by_id         (ai_activated_by_id)
#  index_organisations_on_ai_package_id              (ai_package_id)
#  index_organisations_on_ai_provider                (ai_provider)
#  index_organisations_on_notification_sender_email  (notification_sender_email)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (active_embedding_space_id => embedding_spaces.id) ON DELETE => nullify
#  fk_rails_...  (ai_activated_by_id => users.id) ON DELETE => nullify
#  fk_rails_...  (ai_package_id => ai_packages.id)
#  fk_rails_...  (ai_package_selected_by_id => users.id) ON DELETE => nullify
#
# spec/factories/organisations.rb

FactoryBot.define do
  factory :organisation do
    sequence(:name) { |n| "Test Organisation #{n}" }
    subdomain { 'test' }
    domain { 'test.local' }
    # AI features are opt-in per organisation (GDPR gate, default false in the
    # DB). Test orgs enable them by default so every existing AI-path spec keeps
    # exercising the real behaviour; specs for the gate itself use :ai_disabled.
    ai_enabled { true }

    trait :ai_disabled do
      ai_enabled { false }
    end
  end
end
