# frozen_string_literal: true

FactoryBot.define do
  factory :ai_credential_document do
    ai_credential
    document_key { 'sst' }
    title { 'Service Specific Terms' }
    summary { 'Enthält die Training Restriction für Generative AI.' }
    url { 'https://cloud.google.com/terms/service-terms' }
    locator { 'Abschnitt Generative AI, Training Restriction' }
    valid_from { Date.current }
  end
end
