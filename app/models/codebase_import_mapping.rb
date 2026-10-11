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
# Which local record a Codebase id became, per organisation. Two organisations
# importing the same export carry the same Codebase ids; the tenant scope keeps
# each one's tickets, billing groups and users out of the other's import.
class CodebaseImportMapping < ApplicationRecord
  # The tenant sets the id and the foreign key guarantees the row; checking the
  # id alone spares an import of hundreds of rows one organisation lookup each.
  acts_as_tenant(:organisation, optional: true)
  validates :organisation_id, presence: true

  validates :codebase_id, presence: true
  validates :local_id, presence: true
  validates :entity_type, presence: true

  scope :users, -> { where(entity_type: 'User') }
  scope :tickets, -> { where(entity_type: 'Ticket') }

  def self.find_local_id(codebase_id, entity_type)
    find_by(codebase_id: codebase_id, entity_type: entity_type)&.local_id
  end

  def original_data
    mapping_data&.dig('original_data')
  end

  def action_taken
    mapping_data&.dig('action')
  end
end
