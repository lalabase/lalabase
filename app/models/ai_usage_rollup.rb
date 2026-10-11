# frozen_string_literal: true

# One month of AI consumption for ONE organisation, booked onto the Account that
# bundles it (T17, doc/billing_agentur_konto_plan.md §17.3b).
#
# WHAT IS COUNTED: quota-relevant consumption only -- AiUsage.quota_counted, the
# exact scope Lalabase::Llm::QuotaLedger#used enforces the gate with. BYOK rows
# (own token, no system credential) are logged for transparency but never
# metered against a budget and never billed, so they are deliberately absent
# here. `credits_used` on this table therefore means the same thing it means on
# the quota bar the customer already sees -- the two can never disagree.
# Decision written up in the plan, §17.3b.
#
# WRITE-ONCE. Rows are inserted with ON CONFLICT DO NOTHING (see
# Subscriptions::AiUsageAggregator) and are never updated in place. The only path
# allowed to replace a period is `rake ai_usage_rollups:rebuild`, which deletes
# it first and says so in the log.
#
# The organisation reference is provenance, not an association contract: there
# is no FK, and `organisation` returns nil once the org is deleted -- which is
# the entire reason this table exists. Read the name from `organisation_name`,
# never from `organisation&.name`.
# == Schema Information
#
# Table name: ai_usage_rollups
#
#  id                :uuid             not null, primary key
#  aggregated_at     :datetime         not null
#  cost_cents        :decimal(15, 6)   default(0.0), not null
#  credits_used      :bigint           default(0), not null
#  organisation_name :string           not null
#  partial           :boolean          default(FALSE), not null
#  period_start      :date             not null
#  tokens_used       :bigint           default(0), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  account_id        :uuid             not null
#  organisation_id   :uuid             not null
#
# Indexes
#
#  idx_ai_usage_rollups_account_period  (account_id,period_start)
#  idx_ai_usage_rollups_unique_period   (organisation_id,period_start) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class AiUsageRollup < ApplicationRecord
  # Billing lives ABOVE the tenants: no acts_as_tenant here, deliberately
  # (app/models/CLAUDE.md, trap 3). Adding one would silently filter every row
  # away instead of raising.
  belongs_to :account

  # optional: true is not laxness -- a deleted organisation is the NORMAL end
  # state of these rows.
  belongs_to :organisation, optional: true

  validates :organisation_id, :organisation_name, :period_start, presence: true
  validates :credits_used, :tokens_used, :cost_cents,
            numericality: { greater_than_or_equal_to: 0 }

  scope :for_period, ->(period_start) { where(period_start: period_start) }
  scope :chronological, -> { order(:period_start) }

  # Rows whose organisation is gone. These are the IRREPLACEABLE ones: their
  # ai_usages died with the organisation, so nothing can recompute them --
  # `rake ai_usage_rollups:rebuild` must exclude them from its delete.
  #
  # This scope was removed once as "no caller" and had to come back: the caller
  # that needed it simply had not been written yet, and in the meantime the
  # rebuild task deleted exactly these rows (review finding K1).
  scope :orphaned, -> { where.missing(:organisation) }
  scope :rebuildable, -> { where.associated(:organisation) }

  # True once the organisation this row came from no longer exists.
  def organisation_deleted?
    organisation_id.present? && organisation.nil?
  end
end
