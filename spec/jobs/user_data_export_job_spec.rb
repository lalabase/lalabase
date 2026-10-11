# frozen_string_literal: true

require 'rails_helper'

# Job contract: pending → processing → completed with a real, readable ZIP and
# the "ready" mail; duplicate enqueues are no-ops; after the retries are
# exhausted the export flips to failed with a GENERIC error marker (never an
# exception message — it could carry PII/internals) so the user can request
# again immediately (the throttle ignores failed exports).
RSpec.describe UserDataExportJob, type: :job do
  let(:user) { create(:user) }
  let(:export) { create(:user_data_export, user: user) }

  before { ActiveJob::Base.queue_adapter = :test }

  describe 'happy path' do
    it 'attaches a readable ZIP, completes the export and mails the user' do
      described_class.perform_now(export)

      export.reload
      expect(export).to be_completed
      expect(export.archive).to be_attached
      expect(export.archive.filename.to_s).to match(/\Alalabase-datenauskunft-\d{4}-\d{2}-\d{2}\.zip\z/)
      expect(export.expires_at).to be_within(1.minute).of(UserDataExport::RETENTION.from_now)

      entries = Zip::File.open_buffer(StringIO.new(export.archive.download)).map(&:name)
      expect(entries).to include('README.txt', 'account.json', 'preferences.json')
    end

    it 'enqueues the ready mail' do
      expect { described_class.perform_now(export) }
        .to have_enqueued_mail(UserDataExportMailer, :ready)
    end
  end

  describe 'idempotency' do
    it 'is a no-op on a completed export (duplicate enqueue)' do
      completed = create(:user_data_export, :completed, user: user)

      expect { described_class.perform_now(completed) }
        .not_to have_enqueued_mail(UserDataExportMailer, :ready)
      expect(completed.reload).to be_completed
    end

    it 'is a no-op on a failed export' do
      failed = create(:user_data_export, :failed, user: user)

      described_class.perform_now(failed)
      expect(failed.reload).to be_failed
    end
  end

  describe 'failure path' do
    before do
      allow(UserDataExports::Builder).to receive(:new).and_raise(StandardError, 'secret internal detail')
    end

    it 'flips to failed with a GENERIC error marker after retries are exhausted' do
      perform_enqueued_jobs do
        described_class.perform_later(export)
      rescue StandardError
        # after the final attempt the error is re-raised by the test adapter
      end

      export.reload
      expect(export).to be_failed
      expect(export.error_message).to eq('export_failed')
      expect(export.error_message).not_to include('secret internal detail')
    end
  end
end
