# frozen_string_literal: true

# Clean up existing data: convert BMP attachments to PNG so they get preview images again
# (see BmpAttachmentConversion). Unlike the other tasks in the project, the dry run is the
# default here and the live run needs APPLY=1: the task replaces customer files, an
# accidental run would be expensive.
namespace :bmp_attachments do
  desc 'BMP-Anhaenge nach PNG umwandeln. Trockenlauf ist Standard, scharf mit APPLY=1.'
  task convert: :environment do
    apply = ENV['APPLY'] == '1'
    result = BmpAttachmentConversion.call(
      dry_run: !apply,
      limit: ENV['LIMIT'].presence&.to_i,
      backup_dir: ENV['BACKUP_DIR'].presence
    )

    mode = result.dry_run ? ' (Trockenlauf, nichts geschrieben)' : ' (scharf)'
    puts "bmp_attachments:convert#{mode}"
    puts "  gefunden:      #{result.scanned}"
    puts "  #{result.dry_run ? 'wandelbar:    ' : 'umgewandelt:  '} #{result.converted}"
    puts "  uebersprungen: #{result.skipped}"
    puts "  fehlgeschlagen:#{result.failed}"
    puts format('  Groesse:       %<before>.1f MB -> %<after>.1f MB (spart %<saved>.1f MB)',
                before: result.bytes_before / 1024.0 / 1024,
                after: result.bytes_after / 1024.0 / 1024,
                saved: result.bytes_saved / 1024.0 / 1024)
    result.notes.each { |note| puts "  #{note}" }
    puts '  Originale liegen im Backup-Verzeichnis.' unless result.dry_run || result.converted.zero?
  end
end
