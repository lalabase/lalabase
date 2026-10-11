# frozen_string_literal: true

# After the deploy of migration 20260916120000: assign the existing Codebase
# import mappings to their organisation and list the imported bookings that an
# earlier import linked across organisations. DRY_RUN=1 writes nothing.
# Idempotent. See CodebaseImport::MappingOrganisationBackfill for the rules.
namespace :codebase_import do
  desc 'Assign Codebase import mappings to their organisation (DRY_RUN=1 writes nothing)'
  task scope_mappings: :environment do
    dry_run = ENV['DRY_RUN'] == '1'
    report = CodebaseImport::MappingOrganisationBackfill.call(dry_run: dry_run)
    sample = CodebaseImport::MappingOrganisationBackfill::SAMPLE_SIZE

    puts dry_run ? 'Dry run, nothing written.' : 'Applied.'
    report.assigned.each { |type, count| puts "Assigned #{type}: #{count}" }
    report.unassigned.each { |type, count| puts "Still without organisation #{type}: #{count}" }
    report.foreign_links.each do |kind, ids|
      next if ids.empty?

      puts "Imported bookings with a #{kind} of another organisation: #{ids.size} (#{ids.first(sample).join(', ')})"
    end
  end
end
