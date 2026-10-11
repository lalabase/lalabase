# frozen_string_literal: true

# Runs the idempotent data backfills of Lalabase::DataBackfills::TASKS in order.
# Called after the migrations on every deploy: by our Capistrano deploy and by
# bin/docker-entrypoint (after db:prepare).
namespace :lalabase do
  desc 'Run the idempotent data backfills (after the migrations, on every deploy)'
  task data_backfills: :environment do
    Lalabase::DataBackfills::TASKS.each { |name| Rake::Task[name].invoke }
  end
end
