# frozen_string_literal: true

# Clean up existing data (spike plan "Inline-Bilder", D9): remove url/href from stored
# <action-text-attachment> nodes. Always run with DRY_RUN=1 first.
namespace :rich_text_embeds do
  desc 'url/href aus gespeicherten Attachment-Knoten entfernen. Immer zuerst mit DRY_RUN=1.'
  task strip_urls: :environment do
    dry_run = ENV['DRY_RUN'] == '1'
    result = RichTextEmbedUrlSweep.call(dry_run: dry_run)
    puts format('rich_text_embeds:strip_urls%<mode>s', mode: result.dry_run ? ' (DRY_RUN, nichts geschrieben)' : '')
    puts "  Rich-Texte mit Attachment-Knoten: #{result.scanned}"
    puts "  #{result.dry_run ? 'Würden geändert' : 'Geändert'}: #{result.changed}"
  end

  # After a secret_key_base rotation (RichTextSgidResign). The old key comes from the
  # environment of this one run only; read it with `read -rs OLD_SECRET_KEY_BASE` and
  # export it, so it lands neither in the shell history nor in a file.
  desc 'Attachment-Knoten mit dem aktuellen Schlüssel neu signieren. OLD_SECRET_KEY_BASE setzen, zuerst DRY_RUN=1.'
  task resign_sgids: :environment do
    old_secret_key_base = ENV.fetch('OLD_SECRET_KEY_BASE', '')
    abort 'OLD_SECRET_KEY_BASE fehlt (der Schlüssel VOR dem Tausch).' if old_secret_key_base.blank?
    abort 'OLD_SECRET_KEY_BASE ist der aktuelle Schlüssel.' if old_secret_key_base == Rails.application.secret_key_base

    result = RichTextSgidResign.call(old_secret_key_base: old_secret_key_base, dry_run: ENV['DRY_RUN'] == '1')
    puts format('rich_text_embeds:resign_sgids%<mode>s', mode: result.dry_run ? ' (DRY_RUN, nichts geschrieben)' : '')
    puts "  Rich-Texte mit Attachment-Knoten: #{result.scanned}"
    puts "  #{result.dry_run ? 'Würden geändert' : 'Geändert'}: #{result.changed} Texte, #{result.resigned} Knoten"
    puts "  Mit keinem der beiden Schlüssel lesbar: #{result.unreadable}"
    { gone: 'Ziel fehlt (Blob gelöscht, aus der Sicherung holen)', refused: 'Abgelehnt (gehört nicht zu diesem Text)' }.each do |kind, label|
      rows = result[kind]
      puts "  #{label}: #{rows.size}"
      rows.each do |row|
        puts "    #{row[:record_type]} #{row[:record_id]} (Rich-Text #{row[:rich_text_id]}) -> #{row[:target_type]} #{row[:target_id]}"
      end
    end
  end
end
