# frozen_string_literal: true

# Carries the backup script's own deletion proof over into the deletion register
# (AVV § 12 Abs. 7: "die Bestätigung des Sicherungsablaufs wird nachgetragen").
#
# The script writes one line per file it removed from mirror AND storage box:
#
#   <ISO-8601 UTC>\tgeloescht\t<relative mirror path>\tverwaist_seit=<date>
#
# The path ends in the blob's storage key, and that key is why the register
# stores it from day one: once the file is gone from production, nothing else can
# map this line back to an organisation and a filename.
#
# Two dates, deliberately not one. backup_deleted_at is PROVEN — the script
# verified the copy is gone from both places. backup_expires_at is COMPUTED, by
# adding the storage box's snapshot lag, because those snapshots cannot be
# deleted from the servers and no log line can attest to them. Collapsing both
# into one column would present a calculation as a measurement.
#
# The register's three-year retention does NOT hang on either of them (see
# AttachmentDeletionRecord::RETENTION): this run may never happen for a given
# row, and a proof without an end date is the very defect the register exists to
# document.
class AttachmentBackupConfirmationJob < ApplicationJob
  queue_as :default

  # Path of the script's durable proof. Configurable because the job also runs on
  # staging and in development, where the file legitimately does not exist.
  DEFAULT_LOG_PATH = '/var/lib/lalabase-backup/deletions.log'
  # Marker the script writes for an actual deletion.
  DELETION_MARKER = 'geloescht'

  def perform(log_path: ENV.fetch('LALABASE_DELETION_LOG', DEFAULT_LOG_PATH))
    path = Pathname.new(log_path)
    return unless readable?(path)

    confirmations = parse(path)
    return if confirmations.empty?

    applied = apply(confirmations)

    Rails.logger.info(
      "[deletion_register] backup confirmations: lines=#{confirmations.size} applied=#{applied}"
    )
  end

  private

  # A missing file is normal off production; an unreadable one is not — it means
  # the script's group release never happened, and the register would silently
  # never learn about any expiry.
  def readable?(path)
    return true if path.readable?

    if path.exist?
      Rails.logger.warn("[deletion_register] #{path} exists but is not readable — no confirmations carried over")
    else
      Rails.logger.debug { "[deletion_register] no deletion log at #{path}" }
    end
    false
  end

  # @return [Hash{String => Time}] storage key => deletion timestamp. Later lines
  #   win, which cannot normally happen — a key is deleted once.
  def parse(path)
    path.each_line.with_object({}) do |line, acc|
      stamp, marker, relative_path, = line.chomp.split("\t")
      next unless marker == DELETION_MARKER
      next if stamp.blank? || relative_path.blank?

      key = File.basename(relative_path)
      time = Time.zone.parse(stamp)
      acc[key] = time if time
    rescue ArgumentError
      # A single malformed line must not stop the run: every other confirmation
      # in this file would then never arrive either.
      Rails.logger.warn("[deletion_register] unparsable line in #{path}: #{line.chomp.truncate(120)}")
    end
  end

  # Only fills gaps. Re-running over the same file is a no-op, which matters
  # because the file is cumulative and this job runs daily.
  def apply(confirmations)
    AttachmentDeletionRecord.without_backup_confirmation
                            .where(storage_key: confirmations.keys)
                            .find_each.count do |record|
      deleted_at = confirmations.fetch(record.storage_key)
      record.update!(
        backup_deleted_at: deleted_at,
        backup_expires_at: (deleted_at + AttachmentDeletionRecord::BACKUP_SNAPSHOT_LAG).to_date
      )
    end
  end
end
