# frozen_string_literal: true

require 'rails_helper'

# What this file protects
# -----------------------
# That `limits_concurrency` DOES SOMETHING in this app.
#
# It did not, until P4d. config/initializers/solid_queue.rb class_eval'd its own
# SolidQueue::Job#concurrency_key over the framework's attribute reader; that method
# returned nil for every job, so #concurrency_limited? was false, no semaphore was ever
# taken, and every declaration anywhere was inert. Nothing raised, nothing logged — the
# rule simply did not exist. Two intended rules had lived in that override for a long
# time without ever having run once.
#
# So this runs through the REAL solid_queue adapter rather than asserting on the
# declaration. A class-attribute check (`concurrency_limit == 1`) passes happily against
# a disabled mechanism: the declaration was always correct, it was the reading of it
# that was broken. Only an actual enqueue can tell the two apart.
RSpec.describe 'Solid Queue concurrency control' do
  let(:organisation) { create(:organisation) }

  around do |example|
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :solid_queue
    example.run
  ensure
    ActiveJob::Base.queue_adapter = previous
  end

  # Two enqueues mean Solid Queue asks its own semaphore/job tables twice, and the two
  # identical statements read as an N+1. They are not one — they are the two enqueues
  # this file exists to compare, one per call, inside the queue backend rather than in
  # app code. Paused HERE rather than allowlisted globally: no other spec should get a
  # blanket exemption for repeated solid_queue_* reads. It has to be a `before` rather
  # than the `around` above, because the suite-wide Prosopite.scan runs between them.
  before { Prosopite.pause }

  after { Prosopite.resume }

  def reindex_rows
    SolidQueue::Job.where(class_name: 'Embeddings::ReindexOrganisationJob')
  end

  it 'takes a semaphore for a job that declares a limit' do
    Embeddings::ReindexOrganisationJob.perform_later(organisation)

    expect(SolidQueue::Semaphore.where(key: reindex_rows.first.concurrency_key)).to exist
  end

  # The property P4d's watcher relies on: it re-drives the build on every tick without
  # checking whether one is already running, because a duplicate cannot survive here.
  it 'discards a second enqueue for the same organisation' do
    2.times { Embeddings::ReindexOrganisationJob.perform_later(organisation) }

    expect(reindex_rows.count).to eq(1)
  end

  # The limit is per organisation, not global — one org's switch must not hold up
  # another's. This is the half a `to: 1` alone would get wrong.
  it 'lets a different organisation through' do
    other = create(:organisation)

    Embeddings::ReindexOrganisationJob.perform_later(organisation)
    Embeddings::ReindexOrganisationJob.perform_later(other)

    expect(reindex_rows.count).to eq(2)
  end

  # A job WITHOUT a declaration must stay unaffected — restoring the mechanism must not
  # start serialising the rest of the fleet.
  it 'leaves a job that declares no limit alone' do
    2.times { AiQuotaResumeJob.perform_later(organisation) }

    expect(SolidQueue::Job.where(class_name: 'AiQuotaResumeJob').count).to eq(2)
  end

  it 'blocks a second response writer for the same chat instead of mixing streamed answers' do
    allow(ChatResponseJob).to receive(:perform_later).and_call_original
    ActsAsTenant.with_tenant(organisation) do
      chat = create(:chat, organisation: organisation)
      ChatResponseJob.perform_later(chat)
      ChatResponseJob.perform_later(chat, regenerate_chatpost_id: SecureRandom.uuid)
    end

    rows = SolidQueue::Job.where(class_name: 'ChatResponseJob')
    expect(rows.count).to eq(2)
    expect(SolidQueue::ReadyExecution.where(job_id: rows.select(:id)).count).to eq(1)
    expect(SolidQueue::BlockedExecution.where(job_id: rows.select(:id)).count).to eq(1)
  end
end
