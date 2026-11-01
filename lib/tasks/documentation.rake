# frozen_string_literal: true

namespace :documentation do
  desc 'Sync every documentation set again in full (after a change to how pages are rendered)'
  task resync_all: :environment do
    count = Documentation::ResyncAll.call
    puts "Enqueued a full sync for #{count} documentation #{'set'.pluralize(count)}."
  end
end
