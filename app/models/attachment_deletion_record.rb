# frozen_string_literal: true

# One entry of the deletion register promised by AVV § 12 Abs. 7: metadata of a
# file attachment that left the production system. Never content.
#
# Deliberately NOT acts_as_tenant, and deliberately without a belongs_to to
# Organisation: the entry has to survive the deletion of the very organisation it
# concerns, because that is precisely when a controller asks for proof (end of
# contract, § 12 Abs. 1). A tenant scope would make those rows unfindable, a
# foreign key with the org's dependent: :destroy chain would erase them outright.
# Reading happens through the admin area, like other operator-side data.
# == Schema Information
#
# Table name: attachment_deletion_records
#
#  id                :uuid             not null, primary key
#  backup_deleted_at :datetime
#  backup_expires_at :date
#  byte_size         :bigint
#  content_type      :string
#  deleted_at        :datetime         not null
#  filename          :string           not null
#  organisation_name :string
#  record_type       :string
#  storage_key       :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  organisation_id   :uuid
#  user_id           :uuid
#
# Indexes
#
#  idx_on_organisation_id_deleted_at_be48b83a3b      (organisation_id,deleted_at)
#  index_attachment_deletion_records_on_deleted_at   (deleted_at)
#  index_attachment_deletion_records_on_storage_key  (storage_key)
#
class AttachmentDeletionRecord < ApplicationRecord
  # § 12 Abs. 7: "drei Jahre ab der Löschung im Produktivsystem". Anchored on
  # deleted_at rather than on the backup confirmation, because that column is
  # filled in later and may never arrive (script failure, lost log line, a file
  # that never made it into a backup). An entry without an end date would give
  # this register the very defect it exists to document — see plan § 3.5.
  RETENTION = 3.years
  # Storage-box snapshots outlive the deletion from mirror and box by this much.
  # Used to COMPUTE backup_expires_at, never as a deadline.
  BACKUP_SNAPSHOT_LAG = 14.days

  validates :storage_key, :filename, :deleted_at, presence: true

  scope :for_organisation, ->(organisation_id) { where(organisation_id:) }
  scope :recent_first, -> { order(deleted_at: :desc) }
  # Rows whose backup confirmation never arrived. Must stay visible in any
  # audit answer — hiding them would make the register look more complete than
  # it is.
  scope :without_backup_confirmation, -> { where(backup_deleted_at: nil) }
  scope :due_for_retention, -> { where(deleted_at: ...RETENTION.ago) }
  # Entries whose carrier had no organisation to resolve: user data exports (they
  # span all of a user's organisations) and carriers that could not be resolved
  # at all. They belong to no per-organisation audit answer, so a total that
  # omits them has to say so.
  scope :without_organisation, -> { where(organisation_id: nil) }

  # The day this register started. Attachments deleted before it appear nowhere,
  # and an audit answer has to say so instead of implying completeness.
  def self.register_started_at
    minimum(:created_at)
  end

  # Organisations that appear IN THE REGISTER, for the audit filter. Read from
  # the register itself and never from the organisations table: an entry outlives
  # the organisation it concerns, and that is exactly when the proof gets asked
  # for. A list built from existing organisations would drop every ended contract.
  #
  # @return [Array<Array(String, String)>] id and name, the most recently seen
  #   name per organisation — a rename would otherwise offer the same filter twice.
  def self.organisations_in_register
    where.not(organisation_id: nil)
         .select('DISTINCT ON (organisation_id) organisation_id, organisation_name')
         .order(:organisation_id, deleted_at: :desc)
         .map { |row| [row.organisation_id, row.organisation_name] }
         .sort_by { |_, name| name.to_s.downcase }
  end

  def backup_confirmed?
    backup_deleted_at.present?
  end
end
