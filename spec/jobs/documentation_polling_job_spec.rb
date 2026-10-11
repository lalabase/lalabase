# frozen_string_literal: true

require 'rails_helper'

# What: DocumentationPollingJob — the Slice-2 auto-sync fan-out.
# Type: Job spec.
# Why:  Polling is the only automatic transport (webhooks deferred); it must
#       reach EVERY set across tenants, and each fan-out must be marked as
#       'polling' so runs are distinguishable from manual syncs.
RSpec.describe DocumentationPollingJob, type: :job do
  include ActiveJob::TestHelper

  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
    ActiveJob::Base.queue_adapter = original
  end

  it 'enqueues one sync per set across ALL organisations, tagged as polling' do
    org_a = create(:organisation)
    org_b = create(:organisation)
    set_a = ActsAsTenant.with_tenant(org_a) { create(:documentation_set, project: create(:project, organisation: org_a)) }
    set_b = ActsAsTenant.with_tenant(org_b) { create(:documentation_set, project: create(:project, organisation: org_b)) }

    described_class.perform_now

    expect(DocumentationSyncJob).to have_been_enqueued.with(set_a.id, trigger: 'polling')
    expect(DocumentationSyncJob).to have_been_enqueued.with(set_b.id, trigger: 'polling')
  end

  it 'does not skip a set stuck in syncing (self-healing after a dead worker)' do
    org = create(:organisation)
    stuck = ActsAsTenant.with_tenant(org) do
      create(:documentation_set, project: create(:project, organisation: org), sync_status: 'syncing')
    end

    described_class.perform_now

    expect(DocumentationSyncJob).to have_been_enqueued.with(stuck.id, trigger: 'polling')
  end

  it 'enqueues nothing when no sets exist' do
    described_class.perform_now

    expect(DocumentationSyncJob).not_to have_been_enqueued
  end
end
