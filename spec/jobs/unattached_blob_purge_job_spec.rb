# frozen_string_literal: true

require 'rails_helper'

# What: UnattachedBlobPurgeJob — the deletion deadline for blobs without an
#       attachment row (AVV § 12 Abs. 4).
# Type: Job spec.
# Why:  Two opposite mistakes are expensive here. Purging too little leaves the
#       contract's deletion promise untrue; purging too eagerly deletes files
#       out from under someone whose upload form is still open. Both directions
#       are pinned, including the exact grace-period boundary.
RSpec.describe UnattachedBlobPurgeJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  def blob(created_at:, filename: 'orphan.png')
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new('x' * 64),
      filename: filename,
      content_type: 'image/png'
    ).tap { |b| b.update_column(:created_at, created_at) }
  end

  it 'purges an unattached blob older than the grace period' do
    old = blob(created_at: (described_class::GRACE_PERIOD + 1.day).ago)

    described_class.perform_now

    expect(ActiveStorage::Blob.exists?(old.id)).to be(false)
  end

  it 'keeps a blob that is still within the grace period' do
    fresh = blob(created_at: 1.hour.ago)

    described_class.perform_now

    expect(ActiveStorage::Blob.exists?(fresh.id)).to be(true)
  end

  # Boundary: the direct-upload window is exactly what the grace period protects.
  # A blob AT the cutoff must survive; one just past it must not.
  #
  # Time is frozen on purpose. Without it the cutoff moves between building the
  # blob and running the job, and a blob created "exactly at" the boundary is
  # already milliseconds past it by the time the job computes its own — the test
  # would then assert wall-clock luck instead of the comparison.
  describe 'the grace-period boundary' do
    it 'keeps a blob exactly at the cutoff' do
      freeze_time do
        at_cutoff = blob(created_at: described_class::GRACE_PERIOD.ago)

        described_class.perform_now

        expect(ActiveStorage::Blob.exists?(at_cutoff.id)).to be(true)
      end
    end

    it 'purges a blob one second past the cutoff' do
      freeze_time do
        past_cutoff = blob(created_at: described_class::GRACE_PERIOD.ago - 1.second)

        described_class.perform_now

        expect(ActiveStorage::Blob.exists?(past_cutoff.id)).to be(false)
      end
    end
  end

  it 'never touches an attached blob, however old it is' do
    export = create(:user_data_export, :completed)
    attached_blob = export.archive.blob
    attached_blob.update_column(:created_at, 2.years.ago)

    described_class.perform_now

    expect(ActiveStorage::Blob.exists?(attached_blob.id)).to be(true)
    expect(export.reload.archive).to be_attached
  end

  it 'purges at most MAX_PER_RUN blobs per run' do
    stub_const("#{described_class}::MAX_PER_RUN", 1)
    2.times { |i| blob(created_at: 30.days.ago, filename: "orphan_#{i}.png") }

    expect { described_class.perform_now }.to change(ActiveStorage::Blob, :count).by(-1)
  end

  it 'takes the oldest blobs first when more are due than fit in one run' do
    stub_const("#{described_class}::MAX_PER_RUN", 1)
    oldest = blob(created_at: 300.days.ago, filename: 'oldest.png')
    newer = blob(created_at: 30.days.ago, filename: 'newer.png')

    described_class.perform_now

    expect(ActiveStorage::Blob.exists?(oldest.id)).to be(false)
    expect(ActiveStorage::Blob.exists?(newer.id)).to be(true)
  end

  # A single unreadable blob must not abort the run — the remaining candidates
  # would otherwise never reach their deadline either.
  it 'continues after a blob fails to purge' do
    broken = blob(created_at: 30.days.ago, filename: 'broken.png')
    healthy = blob(created_at: 29.days.ago, filename: 'healthy.png')

    allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_wrap_original do |original|
      raise 'storage unreachable' if original.receiver.id == broken.id

      original.call
    end

    expect { described_class.perform_now }.not_to raise_error
    expect(ActiveStorage::Blob.exists?(healthy.id)).to be(false)
  end

  # The scan and the purge are not one transaction. If an attachment is written
  # in between, the re-check must save the blob.
  it 'skips a blob that got attached between scan and purge' do
    late = blob(created_at: 30.days.ago, filename: 'late.png')
    allow_any_instance_of(ActiveStorage::Blob).to receive_message_chain(:attachments, :exists?).and_return(true)

    described_class.perform_now

    expect(ActiveStorage::Blob.exists?(late.id)).to be(true)
  end

  describe 'recurring registration' do
    it 'is scheduled in production AND staging (anti "documented but never runs")' do
      recurring = YAML.load_file(Rails.root.join('config/recurring.yml'))

      %w[production staging].each do |env|
        entry = recurring.fetch(env).fetch('unattached_blob_purge')
        expect(entry.fetch('class')).to eq(described_class.name)
        expect(entry.fetch('schedule')).to be_present
      end
    end

    # The job ships armed on purpose. If someone later adds an enforcement flag
    # of the EMBEDDINGS_GC_ENFORCE kind, this is where it has to be argued.
    it 'is not gated behind an environment flag' do
      source = Rails.root.join('app/jobs/unattached_blob_purge_job.rb').read

      expect(source).not_to match(/ENV\[/)
    end
  end
end
