# frozen_string_literal: true

# == Schema Information
#
# Table name: codebase_import_mappings
#
#  id              :uuid             not null, primary key
#  entity_type     :string           not null
#  mapping_data    :json
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  codebase_id     :string           not null
#  local_id        :uuid             not null
#  organisation_id :uuid
#
# Indexes
#
#  index_codebase_import_mappings_on_entity_type                  (entity_type)
#  index_codebase_import_mappings_on_local_id_and_entity_type     (local_id,entity_type)
#  index_codebase_import_mappings_on_organisation_and_codebase_id (organisation_id,codebase_id,entity_type) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#
FactoryBot.define do
  factory :codebase_import_mapping do
    association :organisation
    codebase_id { SecureRandom.uuid }
    local_id { SecureRandom.uuid }
    entity_type { 'User' }
    mapping_data do
      {
        action: 'imported',
        original_data: { name: 'Test Entity' }
      }
    end

    trait :user_mapping do
      entity_type { 'User' }
    end

    trait :ticket_mapping do
      entity_type { 'Ticket' }
    end

    trait :with_original_data do
      transient do
        original_data_hash { {} }
      end

      mapping_data do
        {
          action: 'imported',
          original_data: original_data_hash
        }
      end
    end
  end
end
