# frozen_string_literal: true

# The deletion register promised by AVV § 12 Abs. 7: one row per deleted file
# attachment, metadata only, never content (plan: doc/loeschverzeichnis_plan.md).
#
# Two column decisions carry the whole point of the table and must not be
# "tidied up" later:
#
# 1. organisation_id has NO foreign key and NO cascade. Organisation deletes
#    broadly with dependent: :destroy (app/models/organisation.rb:96 ff.), so a
#    proper association would erase this register at exactly the moment it is
#    needed: end of contract with full deletion. organisation_name is
#    denormalised for the same reason — after the org row is gone, an id alone
#    tells nobody which customer the entry belonged to.
#
# 2. storage_key is the join to the backup script's own record
#    (/var/lib/lalabase-backup/deletions.log, whose path column ends in this
#    key). It is what makes the "backup expired" confirmation attributable at
#    all — after the file is gone from production, nothing else can map that
#    line back to an organisation and a filename.
class CreateAttachmentDeletionRecords < ActiveRecord::Migration[8.0]
  def change
    create_table :attachment_deletion_records, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      # Loose references on purpose — see the class comment. No foreign_key,
      # no dependent, so the proof outlives both organisation and user.
      t.uuid :organisation_id
      t.string :organisation_name
      # Only set for user data exports, which are deliberately NOT tenant-bound
      # (they span all of a user's organisations).
      t.uuid :user_id

      t.string :storage_key, null: false
      t.string :filename, null: false
      t.string :content_type
      t.bigint :byte_size
      # Carrier class, so an audit answer can say WHAT was deleted, not just
      # which file ("TicketDocument" vs "UserDataExport").
      t.string :record_type

      # Deletion in the production system. Also the anchor of the three-year
      # retention (plan § 3.5): it is the one date that always exists, whereas
      # the backup columns below are filled in later and may never arrive.
      t.datetime :deleted_at, null: false
      # Proven from the backup script's record.
      t.datetime :backup_deleted_at
      # Computed: backup_deleted_at + 14 days of storage-box snapshots. Recorded
      # because § 12 Abs. 7 lists it among the metadata — NOT used as a deadline.
      t.date :backup_expires_at

      t.timestamps
    end

    add_index :attachment_deletion_records, :storage_key
    add_index :attachment_deletion_records, %i[organisation_id deleted_at]
    # Drives the retention sweep.
    add_index :attachment_deletion_records, :deleted_at
  end
end
