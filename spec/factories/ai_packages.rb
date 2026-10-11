# frozen_string_literal: true

# == Schema Information
#
# Table name: ai_packages
#
#  id                      :uuid             not null, primary key
#  active                  :boolean          default(FALSE), not null
#  description             :text
#  embedding_dims          :integer
#  embedding_model         :string
#  jurisdiction            :string
#  kind                    :string           default("curated"), not null
#  name                    :string           not null
#  position                :integer          default(0), not null
#  processing_region       :string
#  provider_note           :text
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  embedding_credential_id :uuid
#
# Indexes
#
#  index_ai_packages_on_embedding_credential_id  (embedding_credential_id)
#  index_ai_packages_on_name                     (name) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (embedding_credential_id => ai_credentials.id)
#
FactoryBot.define do
  # A complete, valid CURATED package. All curated-mandatory fields are set so
  # the factory stays valid as P1 model validations land — request specs build
  # on this in parallel.
  factory :ai_package do
    kind { 'curated' }
    sequence(:name) { |n| "Europäisch #{n}" }
    description { 'Verarbeitung in Frankreich durch Mistral AI, ein französisches Unternehmen.' }
    jurisdiction { 'eu_native' }
    processing_region { 'Frankreich' }
    provider_note { 'Keine Trainingsnutzung; Aufbewahrung 30 Tage; Sub-Prozessoren laut AVV.' }
    # region: 'eu' is load-bearing, not decoration. The default jurisdiction is
    # 'eu_native', and that claim FAILS CLOSED against a credential whose region
    # nobody stated — so a factory leaving region nil would build the very
    # unprovable AVV claim the validation exists to reject.
    association :embedding_credential, factory: :ai_credential, region: 'eu'
    embedding_model { 'mistral-embed' }
    embedding_dims { 1024 }
    active { false }
    sequence(:position) { |n| n }

    # Both tiers of the E2 ladder, each with its own chat-capable credential —
    # the shape the admin form (§7b.1 option C) always produces.
    trait :with_tiers do
      after(:build) do |package|
        AiPackageTier::KEYS.each_with_index do |key, index|
          package.tiers << build(:ai_package_tier, ai_package: package, key: key,
                                                   label: AiPackageTier::DEFAULT_LABELS.fetch(key),
                                                   position: index)
        end
      end
    end
  end
end
