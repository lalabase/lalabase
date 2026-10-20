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

  # After a secret_key_base rotation (RichTextSgidResign): re-signs the attachment nodes
  # whose target the app stored next to the text. Needs no old key.
  desc 'Attachment-Knoten nach einem Tausch von secret_key_base neu signieren. Immer zuerst mit DRY_RUN=1.'
  task resign_sgids: :environment do
    result = RichTextSgidResign.call(dry_run: ENV['DRY_RUN'] == '1')
    puts format('rich_text_embeds:resign_sgids%<mode>s', mode: result.dry_run ? ' (DRY_RUN, nichts geschrieben)' : '')
    puts "  Rich-Texte mit Attachment-Knoten: #{result.scanned}"
    puts "  #{result.dry_run ? 'Würden geändert' : 'Geändert'}: #{result.changed} Texte, #{result.resigned} Knoten"
    puts "  Nicht zugeordnet: #{result.unmatched.size}"
    result.unmatched.group_by { |row| row[:reason] }.each do |reason, rows|
      puts "    #{reason}: #{rows.size}"
      rows.each do |row|
        target = row[:target_id] ? "#{row[:target_type]} #{row[:target_id]}" : "Datei #{row[:filename].inspect}"
        puts "      #{row[:record_type]} #{row[:record_id]} (Rich-Text #{row[:rich_text_id]}) -> #{target}"
      end
    end
  end
end
