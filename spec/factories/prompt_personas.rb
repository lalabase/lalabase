# frozen_string_literal: true

# == Schema Information
#
# Table name: prompt_personas
#
#  id               :uuid             not null, primary key
#  active           :boolean          default(TRUE), not null
#  key              :string           not null
#  labels           :jsonb            not null
#  position         :integer          default(0), not null
#  prompt_fragments :jsonb            not null
#  system           :boolean          default(FALSE), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  organisation_id  :uuid
#
# Indexes
#
#  index_prompt_personas_on_global_key   (key) UNIQUE WHERE (organisation_id IS NULL)
#  index_prompt_personas_on_org_and_key  (organisation_id,key) UNIQUE WHERE (organisation_id IS NOT NULL)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#
FactoryBot.define do
  factory :prompt_persona do
    # Global by default (organisation_id NULL) — the common case. Pass
    # `organisation: org` for a per-org persona.
    organisation { nil }
    sequence(:key) { |n| "persona_#{n}" }
    labels { { 'de' => 'Test-Persona', 'en' => 'Test persona' } }
    prompt_fragments { { 'de' => 'Test-Intent auf Deutsch.', 'en' => 'Test intent in English.' } }
    position { 0 }
    active { true }
    # add_attribute, not `system { ... }`: `system` collides with Kernel#system,
    # which FactoryBot's DSL would resolve first and raise ArgumentError on.
    add_attribute(:system) { false }

    # The seeded default. Fixed key, so create at most one per spec.
    trait :overview do
      key { PromptPersona::DEFAULT_KEY }
      labels { { 'de' => 'Überblick', 'en' => 'Overview' } }
      prompt_fragments do
        { 'de' => 'Gib einen verständlichen Überblick.', 'en' => 'Give an accessible overview.' }
      end
      position { 0 }
      add_attribute(:system) { true }
    end
  end
end
