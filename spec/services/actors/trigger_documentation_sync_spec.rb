# frozen_string_literal: true

require 'rails_helper'

# What: Actors::TriggerDocumentationSync — marks syncing + enqueues the job.
# Type: Service (actor) spec.
# Why:  Manual sync is the read_write user's only lever; it must both give
#       immediate feedback (syncing) and enqueue exactly one job after commit.
RSpec.describe Actors::TriggerDocumentationSync, type: :service do
  include ActiveJob::TestHelper

  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:set) { create(:documentation_set, project: project) }
  let(:user) { create(:user) }

  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
    ActiveJob::Base.queue_adapter = original
  end

  before { ActsAsTenant.current_tenant = organisation }

  it 'marks the set syncing and enqueues the sync job after commit' do
    expect do
      result = described_class.call(documentation_set: set, current_user: user)
      expect(result).to be_success
    end.to have_enqueued_job(DocumentationSyncJob)
      .with(set.id, trigger: 'manual', triggered_by_user_id: user.id)

    expect(set.reload.sync_status).to eq('syncing')
  end

  it 'maps a nil set to a clean failure result instead of crashing' do
    result = described_class.call(documentation_set: nil, current_user: user)

    expect(result).not_to be_success
    expect(result.errors.join).to include('not found')
  end

  it 'passes a custom trigger through to the job (e.g. Slice-2 polling)' do
    expect do
      described_class.call(documentation_set: set, current_user: user, trigger: 'polling')
    end.to have_enqueued_job(DocumentationSyncJob)
      .with(set.id, trigger: 'polling', triggered_by_user_id: user.id)
  end

  # Actor↔Job seam: have_enqueued_job only checks the enqueue-side arguments; a
  # signature drift on the job (e.g. renaming a keyword arg) would still pass
  # those tests. Actually performing the enqueued job proves the two sides fit
  # through ActiveJob (de)serialization.
  describe 'enqueued job integration' do
    it 'performs the enqueued job end-to-end: set syncs and the run carries trigger + user' do
      clone_dir = Dir.mktmpdir('doc-sync-actor-spec-')
      docs_dir = File.join(clone_dir, set.path_prefix)
      FileUtils.mkdir_p(docs_dir)
      File.write(File.join(docs_dir, 'intro.md'), '# Intro')
      cloner = instance_double(Lalabase::Indexer::GitCloner, cloned_commit: 'seam-commit-1')
      allow(cloner).to receive(:call).and_yield(Pathname.new(clone_dir))
      allow(Lalabase::Indexer::GitCloner).to receive(:new).and_return(cloner)

      described_class.call(documentation_set: set, current_user: user)
      perform_enqueued_jobs

      set.reload
      expect(set.sync_status).to eq('ready')
      expect(set.last_synced_commit).to eq('seam-commit-1')
      expect(set.documentation_pages.pluck(:path)).to contain_exactly('intro.md')

      run = set.documentation_sync_runs.recent.first
      expect(run.trigger).to eq('manual')
      expect(run.triggered_by_user_id).to eq(user.id)
    ensure
      FileUtils.remove_entry(clone_dir, true) if clone_dir
    end
  end
end
