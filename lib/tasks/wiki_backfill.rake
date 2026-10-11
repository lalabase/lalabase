# frozen_string_literal: true

namespace :wiki do
  desc 'Backfill markdown_body + v0 NoteVersion for pre-Wiki notes (idempotent, all tenants)'
  task backfill_notes: :environment do
    seen = 0
    result = Wiki::NoteBackfill.call(on_progress: lambda { |_running|
      seen += 1
      print '.' if (seen % 100).zero?
    })
    puts "\nWiki note backfill done: #{result} (notes seen: #{seen})"
  end
end
