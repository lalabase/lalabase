# frozen_string_literal: true

# The stock after doc/dokumentansicht_plan.md (S1): number every document's
# versions chronologically from 1, per organisation. Run once after the deploy
# that added the column, before the migration that makes it NOT NULL. Idempotent.
namespace :documents do
  desc 'Number the versions of every document chronologically from 1 (all organisations, or one by id)'
  task :number_versions, [:organisation_id] => :environment do |_task, args|
    organisations = args[:organisation_id].present? ? Organisation.where(id: args[:organisation_id]) : Organisation.all
    abort "No organisation #{args[:organisation_id]}" if args[:organisation_id].present? && organisations.none?

    organisations.find_each do |organisation|
      result = Documents::NumberVersions.call(organisation: organisation)
      puts "#{organisation.name} (#{organisation.id}): #{result.documents} documents, #{result.versions} versions numbered"
    end
    puts 'Done.'
  end
end
