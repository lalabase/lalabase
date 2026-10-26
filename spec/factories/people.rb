# frozen_string_literal: true

# Invented names only (no real people in fixtures).
FactoryBot.define do
  factory :person do
    sequence(:name) { |n| "Erika Beispiel #{n}" }
    function { 'Technischer Ansprechpartner' }
    company { 'Beispiel GmbH' }
    sequence(:email) { |n| "person#{n}@example.com" }
    association :organisation
  end
end
