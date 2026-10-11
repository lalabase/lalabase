# frozen_string_literal: true

# The stock after doc/notizen_immer_indexiert_plan.md (10.09.2026): notes and
# document versions are indexed by default now. One run flips every row still
# opted out and enqueues the embedding job for every row never indexed, per
# organisation whose embedding lane is usable. Metered like a save is; run it
# per organisation when in doubt.
namespace :indexing do
  desc 'Flip opted-out notes and document versions to indexed and enqueue the embedding job for every never-indexed one (all organisations, or one by id)'
  task :everything, [:organisation_id] => :environment do |_task, args|
    organisations = args[:organisation_id].present? ? Organisation.where(id: args[:organisation_id]) : Organisation.all
    abort "No organisation #{args[:organisation_id]}" if args[:organisation_id].present? && organisations.none?

    organisations.find_each do |organisation|
      result = Indexing::IndexEverything.call(organisation: organisation)
      tail = result.reason ? ", nothing enqueued (#{result.reason})" : ''
      puts "#{organisation.name} (#{organisation.id}): flipped #{result.flipped}, enqueued #{result.enqueued}#{tail}"
    end
    puts 'Done.'
  end
end
