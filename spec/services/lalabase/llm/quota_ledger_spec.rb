# frozen_string_literal: true

require 'rails_helper'

# S3 KI-Kontingent ledger (plan §4.3, tests 1-8). The ledger is the single source
# for BOTH the gate decision and the consumption UI, so these boundary specs pin
# the exact used/budget/buffer thresholds the gate enforces and the banners show.
#
# Effective limits here come from per-org overrides (deterministic, independent of
# the SystemSetting default) so the boundary trios stay tight and readable.
RSpec.describe Lalabase::Llm::QuotaLedger do
  # budget 10 + buffer 5 → hard limit 15. Grace zone = [10, 15).
  let(:organisation) { create(:organisation, ai_quota_credits_override: 10, ai_quota_buffer_override: 5) }
  let(:quota_credential) { create(:ai_credential, provider: 'openai', included_in_quota: true) }

  # Books `credits` of quota-counted usage in the current month by default.
  # `action` defaults to nil on purpose: that is the shape of a pre-rollout row
  # (ai_usages.action is nullable), so the older specs keep exercising it.
  def book(credits, used_at: Time.current, credential: quota_credential, action: nil)
    AiUsage.create!(organisation: organisation, provider: 'openai', action: action,
                    ai_credential: credential, credits_used: credits, used_at: used_at)
  end

  def ledger
    described_class.for(organisation)
  end

  describe 'effective budget/buffer resolution' do
    it 'uses the per-org override over the SystemSetting default' do
      expect(ledger.budget).to eq(10)
      expect(ledger.buffer).to eq(5)
      expect(ledger.hard_limit).to eq(15)
    end

    it 'falls back to the SystemSetting default when no override is set' do
      SystemSetting.set_ai_quota_monthly_credits(200)
      SystemSetting.set_ai_quota_grace_buffer_credits(200)
      org = create(:organisation)
      expect(described_class.for(org).budget).to eq(200)
      expect(described_class.for(org).buffer).to eq(200)
    end

    it 'treats a 0 override as a hard cap, not "unset"' do
      org = create(:organisation, ai_quota_credits_override: 0, ai_quota_buffer_override: 0)
      expect(described_class.for(org).budget).to eq(0)
      expect(described_class.for(org).hard_limit).to eq(0)
    end

    # Defense: the DB column allows a negative override even though the admin field
    # sets min: 0. The [override, 0].max clamp must survive — a mutation removing it
    # would turn a stray -5 into a negative budget (and a nonsensical grace zone).
    it 'clamps a negative override up to 0' do
      org = create(:organisation, ai_quota_credits_override: -5, ai_quota_buffer_override: -5)
      expect(described_class.for(org).budget).to eq(0)
      expect(described_class.for(org).buffer).to eq(0)
    end
  end

  describe '#within_budget? boundary (feeds the 80% warning, must flip AT the budget)' do
    it 'is true one credit below the budget (n-1)' do
      book(9)
      expect(ledger.within_budget?).to be(true)
    end

    # Boundary n: at EXACTLY the budget the org is no longer "within" — it has
    # entered the grace zone. A mutation of `used < budget` to `used <= budget`
    # would leave it "within" here and mis-fire the 80% warning during grace.
    it 'is false at exactly the budget (n)' do
      book(10)
      expect(ledger.within_budget?).to be(false)
    end
  end

  describe 'boundary trio around the budget (grace zone entry)' do
    it 'is :within below the budget (test 1)' do
      book(9)
      expect(ledger.state).to eq(:within)
      expect(ledger.within_budget?).to be(true)
      expect(ledger.hard_exhausted?).to be(false)
    end

    it 'enters the grace zone exactly at the budget (test 2)' do
      book(10)
      expect(ledger.state).to eq(:grace)
      expect(ledger.in_grace?).to be(true)
      expect(ledger.hard_exhausted?).to be(false)
    end

    it 'stays in grace one credit into the buffer (test 2)' do
      book(11)
      expect(ledger.state).to eq(:grace)
    end
  end

  describe 'boundary trio around the hard limit (test 3)' do
    it 'is still grace one credit below the hard limit' do
      book(14)
      expect(ledger.state).to eq(:grace)
      expect(ledger.hard_exhausted?).to be(false)
    end

    it 'is exhausted exactly at the hard limit' do
      book(15)
      expect(ledger.state).to eq(:exhausted)
      expect(ledger.hard_exhausted?).to be(true)
    end

    it 'is exhausted one credit past the hard limit' do
      book(16)
      expect(ledger.hard_exhausted?).to be(true)
    end
  end

  describe 'zero buffer = hard limit directly at the budget (test 7)' do
    let(:organisation) { create(:organisation, ai_quota_credits_override: 10, ai_quota_buffer_override: 0) }

    it 'allows right up to the budget' do
      book(9)
      expect(ledger.hard_exhausted?).to be(false)
      expect(ledger.state).to eq(:within)
    end

    it 'blocks exactly at the budget (no grace zone at all)' do
      book(10)
      expect(ledger.hard_exhausted?).to be(true)
      expect(ledger.in_grace?).to be(false)
    end
  end

  describe 'only quota-counted usage is summed (tests 6/8)' do
    it 'ignores BYOK (nil credential) and non-metered system usage' do
      non_metered = create(:ai_credential, :not_metered, provider: 'openai')
      book(50, credential: nil)         # BYOK
      book(50, credential: non_metered) # system, but not included_in_quota
      expect(ledger.used).to eq(0)
      expect(ledger.hard_exhausted?).to be(false)
    end
  end

  describe 'calendar-month reset (test 4)' do
    it "counts last month's 23:59 usage in the old month and starts fresh on the 1st" do
      # A booking on the last day of the previous month at 23:59 must NOT count now.
      book(99, used_at: (Time.current.beginning_of_month - 1.second))
      expect(ledger.used).to eq(0)

      # This month's usage counts.
      book(3, used_at: Time.current.beginning_of_month + 1.hour)
      expect(described_class.for(organisation).used).to eq(3)
    end
  end

  describe '#usage_percent' do
    it 'is the percentage of the budget consumed (can exceed 100 in grace)' do
      book(5)
      expect(described_class.for(organisation).usage_percent).to eq(50)
      book(8) # total 13 of budget 10
      expect(described_class.for(organisation).usage_percent).to eq(130)
    end

    it 'is 0 for an unused zero-budget org (no divide-by-zero)' do
      org = create(:organisation, ai_quota_credits_override: 0)
      expect(described_class.for(org).usage_percent).to eq(0)
    end

    # Review 2026-07-13 (codex): a hard-cap org (budget 0) that has spent credits is
    # blocked — the bar must read 100%, not a misleading 0%.
    it 'is 100 for an EXHAUSTED zero-budget (hard-cap) org' do
      org = create(:organisation, ai_quota_credits_override: 0)
      AiUsage.create!(organisation: org, provider: 'openai', ai_credential: quota_credential,
                      credits_used: 3, used_at: Time.current)
      expect(described_class.for(org).usage_percent).to eq(100)
    end
  end

  describe '#history' do
    it 'returns oldest→newest months with per-month usage against the current limit' do
      book(4, used_at: Time.current.beginning_of_month + 1.day)
      book(7, used_at: (Time.current - 1.month).beginning_of_month + 1.day)

      history = described_class.for(organisation).history(months: 3)
      expect(history.size).to eq(3)
      expect(history.map { |h| h[:month] }).to eq(history.map { |h| h[:month] }.sort) # ascending
      expect(history.last[:used]).to eq(4)                # current month
      expect(history[-2][:used]).to eq(7)                 # last month
      expect(history.first[:used]).to eq(0)               # two months ago
      expect(history.last[:budget]).to eq(10)
      expect(history.last[:hard_limit]).to eq(15)
    end
  end

  # The drill-down is a Nachweis: a user who asks "where did my credits go?" must be
  # able to add the detail rows up and land exactly on the month total. That only
  # holds because `used` is SUMMED from the breakdown instead of being fetched by a
  # second query — these specs pin that identity, the nil bucket that would otherwise
  # silently swallow the difference, and the scope that keeps BYOK out of both.
  describe '#history per-action breakdown (by_action)' do
    def current_month_row(months: 3)
      described_class.for(organisation).history(months: months).last
    end

    describe 'total ↔ detail identity' do
      it 'sums exactly to the month total (and to the gate value for this month)' do
        book(6, action: 'chat_message')
        book(4, action: 'semantic_search')
        book(3) # legacy row without an action

        row = current_month_row
        expect(row[:by_action].sum { |entry| entry[:credits] }).to eq(row[:used])
        expect(row[:used]).to eq(13)
        # Same number the gate decides on — total and detail cannot drift apart.
        expect(described_class.for(organisation).used).to eq(13)
      end

      # The nil bucket is the whole reason the identity above survives real data:
      # rows written before the action rollout have action = nil. Dropping them (or
      # filtering them out) would leave the detail rows short of the total without
      # any visible error.
      it 'keeps rows without an action as their own nil bucket' do
        book(5, action: 'chat_message')
        book(7) # pre-rollout row

        row = current_month_row
        expect(row[:by_action].map { |entry| entry[:action] }).to contain_exactly('chat_message', nil)
        expect(row[:by_action].find { |entry| entry[:action].nil? }).to include(credits: 7, count: 1)
        expect(row[:used]).to eq(12)
      end
    end

    describe 'quota_counted still gates the breakdown' do
      # If the breakdown ever queried without the scope, BYOK usage would show up in
      # the Nachweis of an org that was never billed for it — and the detail rows
      # would exceed the month total.
      it 'excludes BYOK and non-metered system usage from the breakdown too' do
        non_metered = create(:ai_credential, :not_metered, provider: 'openai')
        book(2, action: 'chat_message')
        book(50, action: 'summary', credential: nil) # BYOK
        book(50, action: 'summary', credential: non_metered) # system, but not included_in_quota

        row = current_month_row
        expect(row[:by_action]).to eq([{ action: 'chat_message', credits: 2, count: 1 }])
        expect(row[:used]).to eq(2)
      end
    end

    describe 'ordering and counting' do
      it 'sorts descending by credits (biggest consumer first)' do
        2.times { book(1, action: 'summary') } # 2 credits
        book(10, action: 'semantic_search') # 10 credits
        3.times { book(2, action: 'chat_message') } # 6 credits

        expect(current_month_row[:by_action].map { |entry| entry[:action] })
          .to eq(%w[semantic_search chat_message summary])
      end

      # Breaks on the classic mix-up of SUM(credits_used) and COUNT(*): here the
      # cheap action has the MORE calls and the expensive one has the fewer, so
      # swapping the two columns flips both numbers on both rows.
      it 'counts rows for :count and credits for :credits' do
        book(9, action: 'semantic_search')             # 1 call, 9 credits
        3.times { book(1, action: 'chat_message') }    # 3 calls, 3 credits

        expect(current_month_row[:by_action]).to eq(
          [{ action: 'semantic_search', credits: 9, count: 1 },
           { action: 'chat_message', credits: 3, count: 3 }]
        )
      end
    end

    describe 'months without usage' do
      # The view hides the drill-down on these rows, so it must get an empty array
      # rather than a nil it would have to guard against.
      it 'returns an empty breakdown and a zero total' do
        book(4, action: 'chat_message') # current month only

        history = described_class.for(organisation).history(months: 3)
        expect(history.first).to include(used: 0, by_action: [])
        expect(history[-2]).to include(used: 0, by_action: [])
        expect(history.last[:by_action]).to eq([{ action: 'chat_message', credits: 4, count: 1 }])
      end
    end

    describe 'query budget' do
      def count_ai_usage_queries
        count = 0
        sub = ActiveSupport::Notifications.subscribe('sql.active_record') do |_, _, _, _, payload|
          next if %w[SCHEMA TRANSACTION].include?(payload[:name])
          next unless payload[:sql] =~ /FROM\s+"ai_usages"/i

          count += 1
        end
        yield
        count
      ensure
        ActiveSupport::Notifications.unsubscribe(sub)
      end

      # The breakdown must stay ONE aggregate: neither a query per month (N+1) nor a
      # second query for the totals — the second query is also what would allow total
      # and detail to disagree.
      it 'reads ai_usages exactly once, regardless of months and actions' do
        book(2, action: 'chat_message')
        book(3, action: 'summary', used_at: (Time.current - 1.month).beginning_of_month + 1.day)
        book(4, action: 'semantic_search', used_at: (Time.current - 2.months).beginning_of_month + 1.day)
        ledger = described_class.for(organisation.reload)

        queries = count_ai_usage_queries { ledger.history(months: 6) }
        expect(queries).to eq(1)
      end
    end
  end
end
