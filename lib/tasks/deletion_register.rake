# frozen_string_literal: true

# Command-line counterpart to the admin view for the deletion register
# (AVV § 12 Abs. 7, L3 of doc/loeschverzeichnis_plan.md). Both exist on purpose:
# the view is for looking, this one is for producing an answer that can be
# pasted into a letter to a controller, and it keeps working when the admin area
# does not.
#
# Read-only. Nothing in this file writes to or deletes from the register.
#
#   bin/rails deletion_register:report
#   ORG=<uuid> bin/rails deletion_register:report
#   ORG=<uuid> LIMIT=200 bin/rails deletion_register:report
namespace :deletion_register do
  desc 'Report entries of the attachment deletion register (read-only; ORG=<uuid> LIMIT=<n>)'
  task report: :environment do
    organisation_id = ENV.fetch('ORG', nil).presence
    limit = ENV.fetch('LIMIT', 100).to_i

    scope = organisation_id ? AttachmentDeletionRecord.for_organisation(organisation_id) : AttachmentDeletionRecord.all

    # Printed FIRST, and unconditionally. An answer that starts with the numbers
    # invites reading a short list as "little was deleted" instead of "the
    # register is younger than you think".
    started_at = AttachmentDeletionRecord.register_started_at
    if started_at
      puts "Verzeichnis gefuehrt seit:   #{started_at.to_date} (frueher Geloeschtes ist nicht erfasst)"
    else
      puts 'Verzeichnis gefuehrt seit:   noch kein Eintrag vorhanden'
    end
    puts 'Nicht erfasst:               Dateien ohne Verknuepfung in der Datenbank (AVV § 12 Abs. 4)'
    puts "Aufbewahrung:                #{AttachmentDeletionRecord::RETENTION.in_years.to_i} Jahre ab der Loeschung im Produktivsystem"
    puts

    if organisation_id
      name = scope.order(:deleted_at).last&.organisation_name
      puts "Organisation:                #{organisation_id}#{name ? " (#{name})" : ' (kein Eintrag unter dieser Kennung)'}"
    else
      puts "Organisationen im Verzeichnis: #{AttachmentDeletionRecord.organisations_in_register.size}"
      puts "Eintraege ohne Organisation:  #{AttachmentDeletionRecord.without_organisation.count} (Nutzer-Exportarchive und nicht aufloesbare Traeger)"
    end

    total = scope.count
    pending = scope.without_backup_confirmation.count
    puts "Eintraege gesamt:            #{total}"
    # Never hidden and never merged into the total: a row without confirmation
    # is a row whose backup expiry nobody has proven.
    puts "davon ohne Nachtrag:         #{pending} (Sicherungsablauf nicht bestaetigt)"
    puts

    if total.zero?
      puts 'Keine Eintraege.'
      next
    end

    puts "Juengste #{[limit, total].min} Eintraege:"
    # .each, not .find_each: batching would discard the order (and refuses a
    # limit outright), and the newest entries are the point of this list.
    scope.recent_first.limit(limit).each do |record|
      backup =
        if record.backup_confirmed?
          "Sicherung geloescht #{record.backup_deleted_at.to_date}" \
            "#{record.backup_expires_at ? ", Kopien abgelaufen #{record.backup_expires_at}" : ''}"
        else
          'Nachtrag ausstehend'
        end

      puts format('  %<deleted>s  %<org>-24s %<name>-40s %<type>-20s %<backup>s',
                  deleted: record.deleted_at.iso8601,
                  org: (record.organisation_name || 'Organisation unbekannt').truncate(24),
                  name: record.filename.to_s.truncate(40),
                  type: record.record_type.to_s.truncate(20),
                  backup: backup)
    end
  end
end
