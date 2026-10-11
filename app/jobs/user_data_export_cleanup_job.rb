# frozen_string_literal: true

# Retention for the export feature itself (registered in config/recurring.yml —
# guarded by a spec so it cannot silently become "documented but never runs",
# the email_logs anti-pattern from the DSGVO audit 1.3):
# - archives are purged once expires_at has passed (RETENTION window)
# - rows disappear entirely after ROW_RETENTION
class UserDataExportCleanupJob < ApplicationJob
  queue_as :exports

  def perform
    UserDataExport.expired.find_each do |export|
      export.archive.purge if export.archive.attached?
    end

    UserDataExport.stale.find_each(&:destroy!)
  end
end
