# frozen_string_literal: true

# The deletion register's own deadline (AVV § 12 Abs. 7: "drei Jahre ab der
# Löschung im Produktivsystem ... und danach gelöscht").
#
# This is not housekeeping. The register is itself personal data about deleted
# personal data — a filename like "Kuendigung_Mustermann.pdf" carries meaning
# after the file is gone. It is lawful only for as long as the accountability it
# serves can still be demanded (Art. 5 Abs. 2, § 195 BGB). Without this run the
# register would be the one store in the system that enters no deadline at all,
# which is exactly the defect it exists to document.
#
# Anchored on deleted_at, never on backup_deleted_at — see
# AttachmentDeletionRecord::RETENTION. A row whose backup confirmation never
# arrived still expires on time; that is the whole point of the anchor.
class AttachmentDeletionRecordPurgeJob < ApplicationJob
  queue_as :default

  # Bounds memory per statement, not the work per run. There is deliberately NO
  # equivalent of UnattachedBlobPurgeJob::MAX_PER_RUN: a cap there delays a
  # deletion the contract states only as an upper bound ("bis zu"), a cap here
  # would push entries PAST a date the contract promises exactly.
  BATCH_SIZE = 1_000

  def perform
    due = AttachmentDeletionRecord.due_for_retention
    # Read before deleting — afterwards there is nothing left to describe.
    cutoff = AttachmentDeletionRecord::RETENTION.ago
    purged = due.in_batches(of: BATCH_SIZE).delete_all

    # Count only. Naming the entries here would copy the very metadata this run
    # just removed into a second store with its own retention — the register
    # would survive its own deadline in the log.
    Rails.logger.info(
      "[deletion_register] retention: purged=#{purged} cutoff=#{cutoff.to_date.iso8601} " \
      "retention_days=#{AttachmentDeletionRecord::RETENTION.in_days.to_i}"
    )
  end
end
