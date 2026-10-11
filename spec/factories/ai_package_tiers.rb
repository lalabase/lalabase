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
FactoryBot.define do
  factory :ai_package_tier do
    ai_package
    key { 'fast' }
    label { AiPackageTier::DEFAULT_LABELS.fetch('fast') }
    # See spec/factories/ai_packages.rb: the default package claims 'eu_native',
    # and that claim is judged against EVERY referenced credential — a tier with
    # an unstated region would make the parent invalid.
    association :chat_credential, factory: :ai_credential, region: 'eu'
    position { 0 }
  end
end
