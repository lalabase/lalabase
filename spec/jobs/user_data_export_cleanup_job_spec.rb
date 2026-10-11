# frozen_string_literal: true

require 'rails_helper'

# Retention of the export feature itself: archives die at expires_at, rows die
# after ROW_RETENTION. The recurring.yml registration is asserted here so the
# cleanup cannot rot into "documented but never runs" — the exact anti-pattern
# the DSGVO audit flagged for email_logs (1.3).
RSpec.describe UserDataExportCleanupJob, type: :job do
  it 'purges archives of expired exports but keeps the rows' do
    expired = create(:user_data_export, :expired)

    described_class.perform_now

    expect(expired.reload.archive).not_to be_attached
    expect(UserDataExport.exists?(expired.id)).to be(true)
  end

  it 'leaves fresh completed exports untouched' do
    fresh = create(:user_data_export, :completed)

    described_class.perform_now

    expect(fresh.reload.archive).to be_attached
  end

  it 'destroys rows older than ROW_RETENTION' do
    stale = create(:user_data_export, :failed, created_at: 31.days.ago)

    described_class.perform_now

    expect(UserDataExport.exists?(stale.id)).to be(false)
  end

  describe 'recurring registration' do
    it 'is scheduled in production AND staging (anti "documented but never runs")' do
      recurring = YAML.load_file(Rails.root.join('config/recurring.yml'))

      %w[production staging].each do |env|
        entry = recurring.fetch(env).fetch('user_data_export_cleanup')
        expect(entry.fetch('class')).to eq('UserDataExportCleanupJob')
        expect(entry.fetch('schedule')).to be_present
      end
    end
  end
end
