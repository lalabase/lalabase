# frozen_string_literal: true

require 'rails_helper'

# Regression guard for tenant propagation in background jobs.
#
# The app relies on acts_as_tenant (ActiveJobExtensions, prepended globally
# via on_load(:active_job)) to serialize the ActsAsTenant.current_tenant into
# the job data at enqueue time and restore it when the job runs in the worker.
# Solid-Queue workers run tenant-less — WITHOUT this propagation, every job
# that loads tenanted models would crash with NoTenantSet (require_tenant =
# true). No code in the repo tested this mechanism so far; a gem update that
# changes it would otherwise go unnoticed.
#
# IMPORTANT: The app's job specs set current_tenant in the test thread and
# call perform_now — this bypasses the serialization and thus exactly the
# path that carries in production. This spec tests the real roundtrip
# (enqueue → serialization → tenant-less worker → deserialization).
class TenantPropagationProbeJob < ApplicationJob
  class << self
    attr_accessor :seen_tenant
  end

  def perform
    self.class.seen_tenant = ActsAsTenant.current_tenant
  end
end

RSpec.describe 'ActiveJob Tenant-Propagation (acts_as_tenant ActiveJobExtensions)' do
  include ActiveJob::TestHelper

  let(:organisation) { create(:organisation) }

  # The test adapter is mandatory here: perform_enqueued_jobs runs the full
  # serialize→deserialize roundtrip — exactly the path the tenant propagation
  # runs through. perform_now would bypass it.
  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
  end

  before { TenantPropagationProbeJob.seen_tenant = :unset }

  after do
    clear_enqueued_jobs
    ActsAsTenant.current_tenant = nil
  end

  it 'restauriert den Enqueue-Tenant bei der Ausführung im tenant-losen Worker' do
    ActsAsTenant.with_tenant(organisation) { TenantPropagationProbeJob.perform_later }

    # Reproduce the worker reality: the executing thread has NO tenant.
    ActsAsTenant.current_tenant = nil
    perform_enqueued_jobs

    expect(TenantPropagationProbeJob.seen_tenant).to eq(organisation)
  end

  it 'führt tenant-los enqueuete Jobs mit nil-Tenant aus (Enforcement bleibt am Model)' do
    TenantPropagationProbeJob.perform_later

    perform_enqueued_jobs

    expect(TenantPropagationProbeJob.seen_tenant).to be_nil
  end
end
