# frozen_string_literal: true

require 'rails_helper'

# What: the sweeper behind the retention promise of the privacy policy § 4.2
#       (doc/akquise_herkunft.md).
# Type: Job spec against real rows -- the boundary is the whole point and a
#       double would not have one.
# Why:  A retention sentence without a sweeper is prose. Three ways this fails
#       silently: the boundary drifting by a day, the job touching accounts it
#       has no business touching, and updated_at being bumped, which the billing
#       views read as "somebody changed this account".
RSpec.describe AcquisitionPurgeJob do
  # The boundary is only testable with the clock held still: without it, the
  # `.ago` in the scope is evaluated milliseconds AFTER the one in the setup, so
  # the row sitting exactly on the boundary always falls past it.
  include ActiveSupport::Testing::TimeHelpers

  def account_aged(age, acquisition: { 'ref' => 'mail' })
    create(:account).tap do |account|
      account.update_columns(acquisition: acquisition, created_at: age.ago,
                             updated_at: age.ago)
    end
  end

  it 'clears an origin past the retention' do
    account = account_aged(AcquisitionSource::RETENTION + 1.day)

    described_class.perform_now

    expect(account.reload.acquisition).to be_nil
  end

  it 'keeps an origin exactly AT the retention boundary' do
    freeze_time do
      account = account_aged(AcquisitionSource::RETENTION)

      described_class.perform_now

      expect(account.reload.acquisition).to eq('ref' => 'mail')
    end
  end

  it 'clears an origin one second past the boundary' do
    freeze_time do
      account = account_aged(AcquisitionSource::RETENTION + 1.second)

      described_class.perform_now

      expect(account.reload.acquisition).to be_nil
    end
  end

  it 'keeps a fresh origin' do
    account = account_aged(1.month)

    described_class.perform_now

    expect(account.reload.acquisition).to eq('ref' => 'mail')
  end

  it 'clears only the origin, never the account itself' do
    account = account_aged(AcquisitionSource::RETENTION + 1.day)
    name = account.name

    expect { described_class.perform_now }.not_to change(Account, :count)

    expect(account.reload.name).to eq(name)
  end

  it 'does not bump updated_at, which billing reads as a change to the account' do
    account = account_aged(AcquisitionSource::RETENTION + 1.day)
    before = account.updated_at

    described_class.perform_now

    expect(account.reload.updated_at).to be_within(1.second).of(before)
  end

  it 'does nothing when there is nothing to clear' do
    account_aged(AcquisitionSource::RETENTION + 1.day, acquisition: nil)

    expect { described_class.perform_now }.not_to raise_error
  end
end
