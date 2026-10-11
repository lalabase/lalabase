# frozen_string_literal: true

require 'rails_helper'

# What: AttachmentDeletionRecordPurgeJob — the deletion register's own deadline
#       (AVV § 12 Abs. 7, three years from the deletion in production).
# Type: Job spec.
# Why:  The register is personal data about deleted personal data. If this run
#       ever stops working, the one store built to prove that everything enters
#       a deadline would itself enter none. The anchor is the load-bearing part
#       and is pinned from both sides: a row expires on deleted_at even when its
#       backup confirmation never arrived, and a fresh row survives even when
#       its backup already expired.
RSpec.describe AttachmentDeletionRecordPurgeJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  def record(deleted_at:, filename: 'Kuendigung_Mustermann.pdf', **attrs)
    AttachmentDeletionRecord.create!(
      storage_key: SecureRandom.hex(8),
      filename: filename,
      deleted_at: deleted_at,
      **attrs
    )
  end

  it 'purges an entry older than the retention period' do
    old = record(deleted_at: (AttachmentDeletionRecord::RETENTION + 1.day).ago)

    described_class.perform_now

    expect(AttachmentDeletionRecord.exists?(old.id)).to be(false)
  end

  it 'keeps a recent entry' do
    fresh = record(deleted_at: 1.day.ago)

    described_class.perform_now

    expect(AttachmentDeletionRecord.exists?(fresh.id)).to be(true)
  end

  # Time is frozen: without it the cutoff moves between building the row and the
  # job computing its own, so a row created "exactly at" the boundary is already
  # past it — the test would assert wall-clock luck instead of the comparison.
  describe 'the retention boundary' do
    it 'keeps an entry exactly at the cutoff' do
      freeze_time do
        at_cutoff = record(deleted_at: AttachmentDeletionRecord::RETENTION.ago)

        described_class.perform_now

        expect(AttachmentDeletionRecord.exists?(at_cutoff.id)).to be(true)
      end
    end

    it 'purges an entry one second past the cutoff' do
      freeze_time do
        past_cutoff = record(deleted_at: AttachmentDeletionRecord::RETENTION.ago - 1.second)

        described_class.perform_now

        expect(AttachmentDeletionRecord.exists?(past_cutoff.id)).to be(false)
      end
    end
  end

  # The reason the anchor is deleted_at and not the backup confirmation: that
  # confirmation may never arrive (script failure, lost log line, a file that
  # never made it into a backup). Anchoring on it would leave such rows without
  # any end date — the exact defect the register documents.
  describe 'the anchor' do
    it 'purges an expired entry whose backup confirmation never arrived' do
      never_confirmed = record(
        deleted_at: (AttachmentDeletionRecord::RETENTION + 1.day).ago,
        backup_deleted_at: nil,
        backup_expires_at: nil
      )

      described_class.perform_now

      expect(AttachmentDeletionRecord.exists?(never_confirmed.id)).to be(false)
    end

    it 'keeps a recent entry whose backup copies are long gone' do
      confirmed = record(
        deleted_at: 2.months.ago,
        backup_deleted_at: 50.days.ago,
        backup_expires_at: 36.days.ago.to_date
      )

      described_class.perform_now

      expect(AttachmentDeletionRecord.exists?(confirmed.id)).to be(true)
    end

    # Mirror image of the above: an entry old enough to expire but whose backup
    # expiry is recent must still go. Would survive if the job ever fell back to
    # backup_expires_at.
    it 'purges an expired entry whose backup expiry was recorded yesterday' do
      late_confirmation = record(
        deleted_at: (AttachmentDeletionRecord::RETENTION + 1.day).ago,
        backup_deleted_at: 15.days.ago,
        backup_expires_at: 1.day.ago.to_date
      )

      described_class.perform_now

      expect(AttachmentDeletionRecord.exists?(late_confirmation.id)).to be(false)
    end
  end

  it 'purges beyond a single batch' do
    stub_const("#{described_class}::BATCH_SIZE", 2)
    3.times { record(deleted_at: (AttachmentDeletionRecord::RETENTION + 1.day).ago) }

    described_class.perform_now

    expect(AttachmentDeletionRecord.count).to eq(0)
  end

  describe 'logging' do
    it 'reports the number purged' do
      record(deleted_at: (AttachmentDeletionRecord::RETENTION + 1.day).ago)
      allow(Rails.logger).to receive(:info)

      described_class.perform_now

      expect(Rails.logger).to have_received(:info).with(/\[deletion_register\] retention: purged=1/)
    end

    # The log has its own retention and is not this register. Naming the entries
    # here would copy the metadata the run just deleted into a second store —
    # the register would outlive its own deadline in the log.
    it 'names no entry it purged' do
      record(deleted_at: (AttachmentDeletionRecord::RETENTION + 1.day).ago, filename: 'Kuendigung_Mustermann.pdf')
      logged = []
      allow(Rails.logger).to receive(:info) { |message| logged << message.to_s }

      described_class.perform_now

      expect(logged.join("\n")).not_to include('Kuendigung_Mustermann')
    end

    it 'logs a run that had nothing to purge' do
      record(deleted_at: 1.day.ago)
      allow(Rails.logger).to receive(:info)

      described_class.perform_now

      expect(Rails.logger).to have_received(:info).with(/purged=0/)
    end
  end
end
