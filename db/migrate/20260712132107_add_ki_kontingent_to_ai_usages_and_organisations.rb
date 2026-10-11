# frozen_string_literal: true

# S3 KI-Kontingent: turns ai_usages into the universal usage event (who / when /
# via which action / how many credits) and adds the per-org quota overrides.
#
# NULLABLE-FIRST (plan §10, test 32): action stays nullable at the DB level so any
# in-flight writer that predates the credits columns keeps writing without error
# during the rollout. The action *whitelist* is enforced at the model level with
# allow_nil, and the credits columns default to 0 — so an old-shape INSERT is
# still valid. New writers (UsageTracking + the embedding metering paths) always
# set action/credits_used.
class AddKiKontingentToAiUsagesAndOrganisations < ActiveRecord::Migration[8.0]
  def change
    # who triggered the call (nil for system/background jobs); nullify on user
    # deletion so a personal-data erasure never cascades away org usage history.
    add_reference :ai_usages, :user, type: :uuid, null: true, foreign_key: { on_delete: :nullify }, index: true

    # what the call acted on (polymorphic, nullable: a chat message or a search
    # query has no single subject record). Drives the "why is the quota empty?"
    # drill-down by subject.
    add_column :ai_usages, :subject_type, :string, null: true
    add_column :ai_usages, :subject_id, :uuid, null: true
    add_index :ai_usages, %i[subject_type subject_id]

    # the metered action, validated against Lalabase::Llm::ActionRegistry at the
    # model level (allow_nil for rollout compatibility, see class comment).
    add_column :ai_usages, :action, :string, null: true

    # credits this call consumed (abstract integer unit, decoupled from cost_cents).
    # default 0 keeps old-shape INSERTs valid; the ledger only sums rows whose
    # credential is included_in_quota.
    add_column :ai_usages, :credits_used, :integer, null: false, default: 0

    # per-org overrides for the monthly quota + grace buffer (credits). NULL means
    # "use the SystemSetting default"; editable ONLY in the admin backend. Nullable
    # (not defaulted) so a 0 override — a hard cap — stays distinguishable from
    # "unset".
    add_column :organisations, :ai_quota_credits_override, :integer, null: true
    add_column :organisations, :ai_quota_buffer_override, :integer, null: true
  end
end
