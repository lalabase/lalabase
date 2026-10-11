# frozen_string_literal: true

require 'rails_helper'

# What: AiUsageRollupFlushable — the before_destroy rescue on Organisation.
# Type: Model spec (callback ordering).
# Why:  `has_many :ai_usages, dependent: :destroy` registers its own
#       before_destroy at declaration time. Without prepend: true the flush
#       would run AFTER the cascade and aggregate an empty table — and it would
#       do so silently, because "no source rows" is a legitimate outcome
#       everywhere else in this service. The discriminating assertion is
#       therefore always a NON-ZERO rollup after the destroy.
RSpec.describe AiUsageRollupFlushable do
  let(:organisation) { create(:organisation) }
  let(:account) { organisation.account }
  let(:credential) { create(:ai_credential) }

  def book_usage(at:, credits: 10, org: organisation)
    create(:ai_usage, organisation: org, ai_credential: credential, used_at: at,
                      credits_used: credits, tokens_used: 100, cost_cents: 5)
  end

  # Destroying an organisation needs a tenant: its tenant-scoped cascades
  # (roles, memberships, …) raise NoTenantSet otherwise. Whatever deletion path
  # gets built one day will have to do the same — so the test does it too
  # instead of reaching past it.
  def destroy_organisation!(org = organisation)
    ActsAsTenant.with_tenant(org) { org.destroy! }
  end

  describe 'on destroy' do
    it 'rescues the consumption before the dependent: :destroy cascade takes it' do
      book_usage(at: Time.current, credits: 10)
      book_usage(at: Time.current, credits: 7)

      expect { destroy_organisation! }.to change(AiUsageRollup, :count).by(1)

      # Non-zero is the point: a flush running after the cascade would find an
      # empty table and write nothing at all.
      expect(AiUsageRollup.sole).to have_attributes(
        account_id: account.id,
        organisation_id: organisation.id,
        organisation_name: organisation.name,
        credits_used: 17
      )
      expect(AiUsage.count).to eq(0)
    end

    # The plan says "last rollup -> now"; the honest bound is every month that
    # still has source rows. A deletion between month end and the monthly run
    # would otherwise take a whole settled month with it.
    it 'flushes every month with usage, not just the running one' do
      book_usage(at: 2.months.ago, credits: 5)
      book_usage(at: 1.month.ago, credits: 6)
      book_usage(at: Time.current, credits: 7)

      destroy_organisation!

      expect(AiUsageRollup.chronological.pluck(:period_start, :credits_used)).to eq(
        [[2.months.ago.to_date.beginning_of_month, 5],
         [1.month.ago.to_date.beginning_of_month, 6],
         [Date.current.beginning_of_month, 7]]
      )
    end

    it 'marks only the cut-short month as partial' do
      book_usage(at: 1.month.ago)
      book_usage(at: Time.current)

      destroy_organisation!

      expect(AiUsageRollup.chronological.pluck(:period_start, :partial)).to eq(
        [[1.month.ago.to_date.beginning_of_month, false],
         [Date.current.beginning_of_month, true]]
      )
    end

    it 'writes the name snapshot, so the row stays readable without the organisation' do
      book_usage(at: Time.current)
      name = organisation.name

      destroy_organisation!

      rollup = AiUsageRollup.sole
      expect(rollup.organisation).to be_nil
      expect(rollup).to be_organisation_deleted
      expect(rollup.organisation_name).to eq(name)
    end

    it 'does nothing when there is no quota-relevant consumption' do
      create(:ai_usage, organisation: organisation, ai_credential: nil, used_at: Time.current)

      expect { destroy_organisation! }.not_to change(AiUsageRollup, :count)
    end

    # The flush is the LAST chance for this data. Blocking the deletion is the
    # only outcome that keeps it — `rake accounts:backfill` then unblocks it.
    context 'when the organisation has no account' do
      it 'blocks the deletion instead of dropping the consumption' do
        book_usage(at: Time.current)
        organisation.update_columns(account_id: nil)

        expect { destroy_organisation! }
          .to raise_error(Subscriptions::AiUsageAggregator::MissingAccountError)

        expect(Organisation.exists?(organisation.id)).to be(true)
        expect(AiUsage.count).to eq(1)
      end
    end

    # Review finding F1: the per-account rescue on the shared write path also
    # fired in the flush — the deletion completed and the rollup was silently
    # lost. Postgres usually covered for it (a failed statement poisons the
    # transaction), which is a driver side effect, not a guarantee.
    context 'when the rollup write fails' do
      it 'rolls the deletion back instead of losing the consumption' do
        book_usage(at: Time.current)
        allow(AiUsageRollup).to receive(:insert_all)
          .and_raise(ActiveRecord::StatementInvalid, 'connection lost')

        expect { destroy_organisation! }.to raise_error(ActiveRecord::StatementInvalid)

        expect(Organisation.exists?(organisation.id)).to be(true)
        expect(AiUsage.count).to eq(1)
      end
    end
  end

  # Same table, entirely separate callback cycle — the D8 hole that
  # AccountAutoAssignable exists for. `ancestors` alone would only prove the
  # module is included; prepend: true is a claim about ORDER, and this class
  # declares its own `has_many :ai_usages, dependent: :destroy`. So the mirror
  # is checked by destroying through the admin model and demanding a NON-ZERO
  # rollup (review finding F4).
  describe 'Admin::Organisation' do
    it 'is mirrored, and its flush also wins against the cascade' do
      expect(Admin::Organisation.ancestors).to include(described_class)
      book_usage(at: Time.current, credits: 13)
      admin_org = Admin::Organisation.find(organisation.id)

      ActsAsTenant.with_tenant(organisation) { admin_org.destroy! }

      expect(AiUsageRollup.sole).to have_attributes(
        organisation_id: organisation.id, credits_used: 13
      )
      expect(AiUsage.count).to eq(0)
    end
  end
end
