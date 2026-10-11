# frozen_string_literal: true

require 'rails_helper'

# What: Subscriptions::AiUsageAggregator — the monthly AI consumption rollup.
# Type: Service spec.
# Why:  Every number this writes ends up on an invoice, and the rows are
#       write-once: a wrong value cannot be repaired by re-running. The three
#       properties that carry that promise are pinned here — the aggregation
#       scope (quota-relevant only), the month boundary, and the refusal to
#       overwrite an existing period.
RSpec.describe Subscriptions::AiUsageAggregator do
  let(:organisation) { create(:organisation) }
  let(:account) { organisation.account }
  let(:credential) { create(:ai_credential) }
  let(:last_month) { Date.current.prev_month.beginning_of_month }

  # Books quota-relevant usage: a system credential with included_in_quota.
  def book_usage(org: organisation, at: last_month + 5.days, credits: 10, tokens: 100, cost: 5,
                 ai_credential: credential)
    create(:ai_usage, organisation: org, ai_credential: ai_credential, used_at: at,
                      credits_used: credits, tokens_used: tokens, cost_cents: cost)
  end

  describe '.call' do
    it 'aggregates a closed month onto the organisation account' do
      book_usage(credits: 10, tokens: 100, cost: 5)
      book_usage(credits: 7, tokens: 50, cost: 3)

      result = described_class.call(period_start: last_month)

      expect(result.inserted).to eq(1)
      rollup = AiUsageRollup.sole
      expect(rollup).to have_attributes(
        account_id: account.id,
        organisation_id: organisation.id,
        organisation_name: organisation.name,
        period_start: last_month,
        credits_used: 17,
        tokens_used: 150,
        partial: false
      )
      expect(rollup.cost_cents).to eq(8)
    end

    it 'refuses to roll up the running month' do
      expect { described_class.call(period_start: Date.current.beginning_of_month) }
        .to raise_error(ArgumentError, /open period/)
    end

    # The whole point of the scope: BYOK consumption runs on the customer's own
    # token, is never metered against a budget and is never billed. If it landed
    # here, the rollup would disagree with the quota bar the customer sees.
    it 'ignores BYOK usage (no system credential)' do
      book_usage(ai_credential: nil)

      expect(described_class.call(period_start: last_month).inserted).to eq(0)
      expect(AiUsageRollup.count).to eq(0)
    end

    it 'ignores system credentials that are not part of the quota' do
      book_usage(ai_credential: create(:ai_credential, :not_metered))

      expect(described_class.call(period_start: last_month).inserted).to eq(0)
    end

    # Same boundary as Lalabase::Llm::QuotaLedger#used. A row one second outside
    # the month must not shift into it, or two systems would report different
    # numbers for the same period.
    it 'counts the very last moment of the month and nothing after it' do
      book_usage(at: last_month.in_time_zone.end_of_month, credits: 4)
      book_usage(at: last_month.in_time_zone.end_of_month + 1.second, credits: 99)
      book_usage(at: last_month.in_time_zone.beginning_of_month - 1.second, credits: 99)

      described_class.call(period_start: last_month)

      expect(AiUsageRollup.sole.credits_used).to eq(4)
    end

    context 'when the period was already written' do
      # Write-once is the structural defence: the aggregation scope INNER JOINs
      # ai_credentials, so a credential that is later deleted (nullify) or taken
      # out of the quota would make a re-run write SMALLER numbers over a
      # settled month.
      it 'leaves the existing row untouched even when the source data shrank' do
        book_usage(credits: 10)
        described_class.call(period_start: last_month)

        AiUsage.update_all(ai_credential_id: nil) # simulates the nullify
        result = described_class.call(period_start: last_month)

        expect(result.inserted).to eq(0)
        expect(AiUsageRollup.sole.credits_used).to eq(10)
      end

      # Review finding F2: with account_id in the unique key, moving an org to
      # another Account let a re-run insert a SECOND row for a settled period —
      # the same month counted on two accounts. The monthly job re-checks six
      # months every run, so this is a standing path, not an exotic one.
      it 'does not book the period a second time when the organisation moves accounts' do
        book_usage(credits: 10)
        described_class.call(period_start: last_month)
        original_account_id = organisation.account_id

        organisation.update!(account: create(:account))
        described_class.call(period_start: last_month)

        rollups = AiUsageRollup.for_period(last_month)
        expect(rollups.count).to eq(1)
        expect(rollups.sum(:credits_used)).to eq(10)
        # The settled period keeps the account it was booked on.
        expect(rollups.sole.account_id).to eq(original_account_id)
      end

      it 'does not overwrite a flushed period whose source rows are gone' do
        create(:ai_usage_rollup, account: account, organisation_id: organisation.id,
                                 period_start: last_month, credits_used: 42, partial: true)

        described_class.call(period_start: last_month)

        expect(AiUsageRollup.sole).to have_attributes(credits_used: 42, partial: true)
      end
    end

    context 'when an organisation has no account' do
      before { organisation.update_columns(account_id: nil) }

      it 'skips it, counts it and keeps going for the others' do
        other = create(:organisation)
        book_usage
        book_usage(org: other)

        result = described_class.call(period_start: last_month)

        expect(result).to have_attributes(inserted: 1, skipped_without_account: 1)
        expect(AiUsageRollup.sole.organisation_id).to eq(other.id)
      end
    end

    # Plan §17.3: one broken account must not cost every other account its
    # month.
    it 'isolates a failing account from the rest' do
      other = create(:organisation)
      book_usage
      book_usage(org: other)
      call_count = 0
      allow(AiUsageRollup).to receive(:insert_all).and_wrap_original do |original, *args, **kwargs|
        call_count += 1
        raise ActiveRecord::StatementInvalid, 'boom' if call_count == 1

        original.call(*args, **kwargs)
      end

      result = described_class.call(period_start: last_month)

      expect(result.inserted).to eq(1)
      expect(AiUsageRollup.count).to eq(1)
    end
  end

  # The failure mode used to be two parameters compared against :raise, so any
  # value that was not exactly :raise meant "swallow" — on the path that is the
  # last chance for these numbers. Now it is one parameter, validated, and the
  # default is the safe branch.
  describe 'failure mode' do
    it 'rejects an unknown mode instead of quietly swallowing failures' do
      expect { described_class.new.aggregate(period_start: last_month, on_failure: :ignore) }
        .to raise_error(ArgumentError, /on_failure must be one of/)
    end

    # The isolation used to catch ActiveRecordError only, so anything else took
    # every OTHER account's month down with it. A non-AR error is the case that
    # widening to StandardError is FOR, and the case no existing example covers.
    it 'isolates a failure that is not a database error' do
      other = create(:organisation)
      book_usage
      book_usage(org: other)
      call_count = 0
      allow(AiUsageRollup).to receive(:insert_all).and_wrap_original do |original, *args, **kwargs|
        call_count += 1
        raise TypeError, 'not a database error' if call_count == 1

        original.call(*args, **kwargs)
      end

      expect(described_class.call(period_start: last_month).inserted).to eq(1)
      expect(AiUsageRollup.count).to eq(1)
    end

    it 'defaults to raising' do
      book_usage
      allow(AiUsageRollup).to receive(:insert_all).and_raise(ActiveRecord::StatementInvalid, 'boom')

      expect { described_class.new.aggregate(period_start: last_month) }
        .to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  describe '.missing_periods' do
    it 'reports a closed period that has usage but no rollup' do
      book_usage

      gaps = described_class.missing_periods(months: 6)

      expect(gaps).to contain_exactly(
        { period_start: last_month, organisation_id: organisation.id }
      )
    end

    it 'reports nothing once the period was written' do
      book_usage
      described_class.call(period_start: last_month)

      expect(described_class.missing_periods(months: 6)).to be_empty
    end
  end
end
