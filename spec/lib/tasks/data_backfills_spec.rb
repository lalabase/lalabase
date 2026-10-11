# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: `rake lalabase:data_backfills`, the one entry point for the idempotent
#       data backfills of Lalabase::DataBackfills::TASKS.
# Type: Rake task spec.
# Why:  Our Capistrano deploy and the Docker image both call this task. If the
#       image stopped calling it, a self-hosted installation would silently miss
#       every backfill our servers get, and nothing else would notice.
RSpec.describe 'lalabase:data_backfills' do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('lalabase:data_backfills')
  end

  before { Rake::Task['lalabase:data_backfills'].reenable }

  it 'lists only tasks that exist' do
    missing = Lalabase::DataBackfills::TASKS.reject { |name| Rake::Task.task_defined?(name) }

    expect(missing).to be_empty
  end

  it 'runs every listed backfill once, in the listed order' do
    invoked = []
    Lalabase::DataBackfills::TASKS.each do |name|
      allow(Rake::Task[name]).to receive(:invoke) { invoked << name }
    end

    Rake::Task['lalabase:data_backfills'].invoke

    expect(invoked).to eq(Lalabase::DataBackfills::TASKS)
  end

  it 'is run by the Docker image right after db:prepare' do
    entrypoint = Rails.root.join('bin/docker-entrypoint').read

    expect(entrypoint).to include('./bin/rails db:prepare lalabase:data_backfills')
  end
end
