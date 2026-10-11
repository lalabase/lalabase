# frozen_string_literal: true

require 'rails_helper'

# What: AiUsageRollupJob — the monthly consumption rollup (T17).
# Type: Job spec.
# Why:  Two properties are easy to break by "tidying up" the job: it must never
#       touch the running month (rows are write-once, a partial value would be
#       permanent), and it must re-check the recent past so a missed run heals
#       itself instead of leaving a hole nobody notices until an invoice.
RSpec.describe AiUsageRollupJob do
  let(:organisation) { create(:organisation) }
  let(:credential) { create(:ai_credential) }

  def book_usage(at:, credits: 10)
    create(:ai_usage, organisation: organisation, ai_credential: credential, used_at: at,
                      credits_used: credits, tokens_used: 100, cost_cents: 5)
  end

  it 'rolls up the months that have closed' do
    book_usage(at: 1.month.ago, credits: 11)
    book_usage(at: 3.months.ago, credits: 33)

    described_class.perform_now

    expect(AiUsageRollup.chronological.pluck(:period_start, :credits_used)).to eq(
      [[3.months.ago.to_date.beginning_of_month, 33],
       [1.month.ago.to_date.beginning_of_month, 11]]
    )
  end

  it 'leaves the running month alone' do
    book_usage(at: Time.current)

    described_class.perform_now

    expect(AiUsageRollup.count).to eq(0)
  end

  it 'heals a missed run without rewriting what is already settled' do
    book_usage(at: 1.month.ago, credits: 11)
    described_class.perform_now
    book_usage(at: 2.months.ago, credits: 22)

    expect { described_class.perform_now }.to change(AiUsageRollup, :count).by(1)

    expect(AiUsageRollup.for_period(1.month.ago.to_date.beginning_of_month).sole.credits_used)
      .to eq(11)
  end

  it 'looks no further back than the catch-up window' do
    book_usage(at: 8.months.ago, credits: 88)

    described_class.perform_now(catch_up_months: 6)

    expect(AiUsageRollup.count).to eq(0)
  end

  # A period with usage but no rollup means the write did not happen and could
  # not be repaired — the only remaining cause is a missing Account. Silence
  # here is what turns a stopped scheduler into a wrong invoice.
  it 'logs the periods it could not book' do
    book_usage(at: 1.month.ago)
    organisation.update_columns(account_id: nil)
    allow(Rails.logger).to receive(:error)

    described_class.perform_now

    expect(Rails.logger).to have_received(:error).with(/without a rollup/)
  end
end
