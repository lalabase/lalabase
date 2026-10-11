# frozen_string_literal: true

namespace :projects do
  desc 'Backfill default attributes (status, priority) for existing projects'
  task backfill_default_attributes: :environment do
    total = Project.count
    updated = 0

    Project.find_each do |project|
      ActsAsTenant.with_tenant(project.organisation) do
        Projects::DefaultAttributeService.new(project).call
        updated += 1
        print "\rProcessed #{updated}/#{total} projects..."
      end
    end

    puts "\nDone. Processed #{updated} projects."
  end
end
