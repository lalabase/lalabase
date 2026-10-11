# frozen_string_literal: true

# Deletion retention for Active Storage blobs that carry no attachment row.
#
# Why this exists (AVV § 12 Abs. 4): every other deletion path starts with a
# record disappearing from the production system — the blob is then orphaned in
# the backup mirror and expires through the 35 + 14 day chain. A blob WITHOUT an
# attachment row never takes that first step: nothing deletes it, so it never
# becomes orphaned, so it never enters any deadline. Rails does not sweep them;
# until this job existed the contract's deletion promise was untrue for them.
#
# They are produced by ordinary use: an image is dropped into a rich text via
# direct upload, removed again, and the text is saved — the blob stays behind.
#
# GRACE_PERIOD is the load-bearing part. `direct_upload: true` runs in eight
# forms (tickets, posts, documents, codebase import), and the codebase import
# even attaches its blob in a LATER request via params[:archive_file_blob_id].
# Between upload and save a legitimate blob is indistinguishable from an
# abandoned one, so anything younger than the grace period is off limits. Seven
# days costs nothing in data protection terms — the backup chain keeps the file
# ~50 days anyway — but it makes hitting an open draft practically impossible.
#
# Deliberately NOT behind an enforcement flag. Embeddings::OrphanGcJob ships as a
# dry run awaiting EMBEDDINGS_GC_ENFORCE=1, that flag was never set, and its
# 24-hour promise (§ 12 Abs. 5) has been uncovered ever since. A second switch of
# the same kind would become the same forgotten switch. Safety comes from the
# grace period and MAX_PER_RUN instead: a mistake surfaces in the log across
# several nights rather than clearing everything in one.
class UnattachedBlobPurgeJob < ApplicationJob
  queue_as :default

  # Minimum age before a blob without an attachment is considered abandoned.
  GRACE_PERIOD = 7.days
  # Upper bound per run, so a wrong scope shows up in the log instead of
  # emptying the store overnight.
  MAX_PER_RUN = 500

  def perform
    candidates = ActiveStorage::Blob.unattached
                                    .where(created_at: ...GRACE_PERIOD.ago)
                                    .order(:created_at)
                                    .limit(MAX_PER_RUN)

    purged = 0
    failed = 0

    candidates.each do |blob|
      # Re-check immediately before deleting: the scan and the purge are not one
      # transaction, and an attachment may have been written in between.
      next if blob.attachments.exists?

      if purge(blob)
        purged += 1
      else
        failed += 1
      end
    end

    Rails.logger.info(
      "[unattached_blob_purge] purged=#{purged} failed=#{failed} " \
      "grace_period_days=#{GRACE_PERIOD.in_days.to_i} limit=#{MAX_PER_RUN}"
    )
  end

  private

  # Purges one blob and records WHAT was deleted — metadata only, never content.
  # A single broken blob (missing file, storage error) must not abort the run:
  # the remaining candidates would then never reach their deadline either.
  def purge(blob)
    metadata = describe(blob)
    blob.purge
    Rails.logger.info("[unattached_blob_purge] purged #{metadata}")
    true
  rescue StandardError => e
    Rails.logger.error("[unattached_blob_purge] FAILED #{metadata} error=#{e.class}: #{e.message}")
    false
  end

  def describe(blob)
    "id=#{blob.id} key=#{blob.key} filename=#{blob.filename} " \
      "content_type=#{blob.content_type} bytes=#{blob.byte_size} created_at=#{blob.created_at.iso8601}"
  end
end
