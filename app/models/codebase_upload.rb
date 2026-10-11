# frozen_string_literal: true

# == Schema Information
#
# Table name: codebase_uploads
#
#  id                 :uuid             not null, primary key
#  file_name          :string           not null
#  file_path          :string
#  linked_object_type :string           not null
#  processed          :boolean          default(FALSE)
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  codebase_upload_id :string           not null
#  import_session_id  :string           not null
#  linked_object_id   :string           not null
#  organisation_id    :uuid             not null
#
# Indexes
#
#  idx_on_codebase_upload_id_organisation_id_d46c273408   (codebase_upload_id,organisation_id)
#  idx_on_linked_object_type_linked_object_id_88d5bd8833  (linked_object_type,linked_object_id)
#  index_codebase_uploads_on_import_session_id            (import_session_id)
#  index_codebase_uploads_on_organisation_id              (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#
class CodebaseUpload < ApplicationRecord
  LINKED_TYPE_TICKET_UPDATE = 'Tickets::Update'
  LINKED_TYPE_PROJECT_FILE = 'ProjectFile'
  LINKED_TYPE_ACCOUNT = 'Account'
  LINKED_TYPES = [LINKED_TYPE_TICKET_UPDATE, LINKED_TYPE_PROJECT_FILE, LINKED_TYPE_ACCOUNT].freeze

  acts_as_tenant :organisation

  belongs_to :organisation

  validates :codebase_upload_id, presence: true
  validates :file_name, presence: true
  validates :linked_object_type, presence: true, inclusion: { in: LINKED_TYPES }
  validates :linked_object_id, presence: true
  validates :import_session_id, presence: true

  scope :ticket_uploads, -> { where(linked_object_type: LINKED_TYPE_TICKET_UPDATE) }
  scope :project_file_uploads, -> { where(linked_object_type: LINKED_TYPE_PROJECT_FILE) }
  scope :unprocessed, -> { where(processed: false) }
  scope :processed, -> { where(processed: true) }
  scope :for_session, ->(session_id) { where(import_session_id: session_id) }

  def ticket_update?
    linked_object_type == LINKED_TYPE_TICKET_UPDATE
  end

  def project_file?
    linked_object_type == LINKED_TYPE_PROJECT_FILE
  end

  def account_file?
    linked_object_type == LINKED_TYPE_ACCOUNT
  end

  def file_exists?
    file_path.present? && File.exist?(file_path)
  end

  def mark_as_processed!
    update!(processed: true)
  end
end
