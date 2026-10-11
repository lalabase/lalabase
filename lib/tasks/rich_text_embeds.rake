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
end
