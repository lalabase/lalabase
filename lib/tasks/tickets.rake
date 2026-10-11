# frozen_string_literal: true

namespace :tickets do
  desc 'Add a Backlog status option (is_backlog) to existing projects that lack one (idempotent)'
  task add_backlog_status: :environment do
    result = Projects::BacklogStatusBackfillService.call
    puts "Backlog-Status-Backfill: #{result.added} ergänzt, #{result.skipped} übersprungen (bereits vorhanden), " \
         "#{result.failed} fehlgeschlagen (siehe Log)."
  end
end
