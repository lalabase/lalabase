# frozen_string_literal: true

# Builds the ZIP for a requested personal data export (Art. 15/20) and mails
# the "ready" notification. Own queue (:exports) so a large archive build never
# blocks user-facing default-queue jobs; the queue.yml workers poll "*".
#
# Failure contract: one retry, then the export flips to failed with a GENERIC
# error marker (never an exception message — it could carry PII/internals).
# A failed export does not count towards the request throttle, so the user can
# immediately request again.
class UserDataExportJob < ApplicationJob
  queue_as :exports

  retry_on StandardError, wait: 30.seconds, attempts: 2 do |job, error|
    export = job.arguments.first
    # The row can vanish mid-flight (account erasure purges exports, hard
    # deletes cascade) — a failed marker on a gone export is meaningless.
    export.update!(status: :failed, error_message: 'export_failed') if export && UserDataExport.exists?(export.id)
    Rails.logger.error(
      "UserDataExportJob failed for export #{export&.id}: #{error.class}"
    )
  end

  def perform(export)
    # Idempotency: a duplicate enqueue on a finished export is a no-op; a
    # retry re-enters with status processing and rebuilds from scratch.
    return if export.completed? || export.failed?

    export.update!(status: :processing)

    Dir.mktmpdir do |dir|
      files = UserDataExports::Builder.new(export.user).files
      zip_path = UserDataExports::ArchiveWriter.write(files, into_dir: dir)
      export.archive.attach(
        io: File.open(zip_path),
        filename: "lalabase-datenauskunft-#{Date.current.iso8601}.zip",
        content_type: 'application/zip'
      )
    end

    export.update!(
      status: :completed,
      completed_at: Time.current,
      expires_at: UserDataExport::RETENTION.from_now,
      error_message: nil
    )

    UserDataExportMailer.with(user_data_export: export).ready.deliver_later
  end
end
