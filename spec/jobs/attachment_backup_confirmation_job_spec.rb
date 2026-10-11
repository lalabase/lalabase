# frozen_string_literal: true

require 'rails_helper'

# What: Carries the backup script's deletion proof into the register (AVV § 12 Abs. 7).
# Type: Job spec.
# Why:  This job is the only bridge between a root-owned text file on the server
#       and a contractual statement. It must be exact about WHAT is proven
#       (deletion from mirror and box) versus what is merely computed (snapshot
#       expiry), and it must never let one bad line cost the other confirmations.
RSpec.describe AttachmentBackupConfirmationJob, type: :job do
  let(:log_path) { Rails.root.join('tmp', "deletions_#{SecureRandom.hex(4)}.log") }

  def write_log(*lines)
    File.write(log_path, lines.map { |line| "#{line}\n" }.join)
    log_path.to_s
  end

  def line_for(key, stamp: '2026-09-10T03:20:15Z', orphaned: '2026-08-05')
    "#{stamp}\tgeloescht\tab/cd/#{key}\tverwaist_seit=#{orphaned}"
  end

  def entry(storage_key:, **attrs)
    AttachmentDeletionRecord.create!(
      storage_key: storage_key, filename: 'brief.pdf', deleted_at: 40.days.ago, **attrs
    )
  end

  after { FileUtils.rm_f(log_path) }

  it 'stamps the proven deletion date on the matching entry' do
    record = entry(storage_key: 'abc123')
    path = write_log(line_for('abc123'))

    described_class.perform_now(log_path: path)

    expect(record.reload.backup_deleted_at).to eq(Time.utc(2026, 9, 10, 3, 20, 15))
  end

  # The snapshot lag is computed, not proven — but it must be computed, because
  # the contract lists the expiry of the backups among the metadata.
  it 'computes the expiry as deletion plus the snapshot lag' do
    record = entry(storage_key: 'abc123')
    path = write_log(line_for('abc123'))

    described_class.perform_now(log_path: path)

    expect(record.reload.backup_expires_at).to eq(Date.new(2026, 9, 24))
  end

  it 'ignores keys the register does not know' do
    path = write_log(line_for('never-seen-key'))

    confirmed = -> { AttachmentDeletionRecord.where.not(backup_deleted_at: nil).count }

    expect { described_class.perform_now(log_path: path) }.not_to change(confirmed, :call)
  end

  # The file is cumulative and this runs daily, so re-reading must not rewrite
  # dates that are already there.
  it 'leaves an already confirmed entry untouched' do
    confirmed_at = Time.utc(2026, 9, 1, 1, 0, 0)
    record = entry(storage_key: 'abc123', backup_deleted_at: confirmed_at)
    path = write_log(line_for('abc123'))

    described_class.perform_now(log_path: path)

    expect(record.reload.backup_deleted_at).to eq(confirmed_at)
  end

  it 'only reacts to actual deletion lines' do
    record = entry(storage_key: 'abc123')
    path = write_log("2026-09-10T03:20:15Z\tgedrosselt\tab/cd/abc123\tverwaist_seit=2026-08-05")

    described_class.perform_now(log_path: path)

    expect(record.reload.backup_deleted_at).to be_nil
  end

  # One broken line must not cost every other confirmation in the same file.
  #
  # The value matters: a line without the deletion marker never reaches the
  # parsing, and free text like "kaputt" merely returns nil from Time.zone.parse.
  # Only a value that LOOKS like a timestamp but carries an impossible component
  # raises — i.e. a write that was torn mid-line, which is exactly the failure the
  # backup script's own state handling guards against elsewhere.
  it 'applies the good lines despite a corrupt timestamp on another' do
    record = entry(storage_key: 'abc123')
    path = write_log("2026-09-10T03:20:99Z\tgeloescht\tab/cd/xyz789\tverwaist_seit=2026-08-05",
                     line_for('abc123'))

    described_class.perform_now(log_path: path)

    expect(record.reload.backup_deleted_at).to be_present
  end

  it 'skips a line whose timestamp is not a date at all' do
    record = entry(storage_key: 'abc123')
    path = write_log("kein-datum\tgeloescht\tab/cd/abc123\tverwaist_seit=2026-08-05")

    described_class.perform_now(log_path: path)

    expect(record.reload.backup_deleted_at).to be_nil
  end

  it 'skips a truncated line without a path' do
    record = entry(storage_key: 'abc123')
    path = write_log("2026-09-10T03:20:15Z\tgeloescht", line_for('abc123'))

    described_class.perform_now(log_path: path)

    expect(record.reload.backup_deleted_at).to be_present
  end

  describe 'when the log cannot be read' do
    it 'does nothing and does not raise when the file is absent' do
      entry(storage_key: 'abc123')

      expect { described_class.perform_now(log_path: '/nonexistent/deletions.log') }
        .not_to raise_error
    end

    # The realistic production failure: the script's group release was never set
    # up, so the file exists but the worker cannot read it. Silence there would
    # mean the register never learns of any expiry, forever.
    it 'warns when the file exists but is unreadable' do
      path = write_log(line_for('abc123'))
      FileUtils.chmod(0o000, path)
      allow(Rails.logger).to receive(:warn)

      described_class.perform_now(log_path: path)

      expect(Rails.logger).to have_received(:warn).with(/is not readable/)
    ensure
      FileUtils.chmod(0o600, path)
    end
  end

  describe 'recurring registration' do
    it 'is scheduled in production AND staging (anti "documented but never runs")' do
      recurring = YAML.load_file(Rails.root.join('config/recurring.yml'))

      %w[production staging].each do |env|
        entry = recurring.fetch(env).fetch('attachment_backup_confirmation')
        expect(entry.fetch('class')).to eq(described_class.name)
        expect(entry.fetch('schedule')).to be_present
      end
    end
  end
end
