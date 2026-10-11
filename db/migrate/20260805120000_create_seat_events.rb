# frozen_string_literal: true

# T16 (doc/billing_agentur_konto_plan.md §17.2): append-only log of WHEN a
# billable seat starts and stops. Rows are inserted and never updated, never
# deleted.
#
# Why a log at all: Subscriptions::SeatCounter counts the CURRENT state, and the
# current state cannot carry its own history (§17.1) -- `memberships` has no
# history columns, a reactivation reuses the same row because of the unique
# index on (user_id, organisation_id), and all four removal paths hard-delete
# the row. A user who was a paid seat for three months and then deletes their
# account leaves nothing behind for the invoice.
#
# Three deliberate schema properties:
#
# 1. NO foreign key on organisation_id, user_id or role_id. These rows have to
#    outlive all three -- an organisation is hard-deleted, a membership is
#    hard-deleted, and a user is soft-deleted and anonymised
#    (User::DeletionLifecycle#soft_delete_and_anonymize!). An FK would either
#    cascade the history away or block the deletion. account_id DOES carry one:
#    the account is the billing level itself, it is delete-protected, and a
#    seat event without it could never reach an invoice.
# 2. organisation_name is a SNAPSHOT for the same reason it is one on
#    ai_usage_rollups (T17): after the organisation is gone, an unlabelled UUID
#    on an invoice is unusable. user_id is deliberately NOT accompanied by a
#    name or e-mail snapshot -- §17.4 decided that the id is kept (without it
#    the dedup rule D4.1 is no longer verifiable) while the resolution to a name
#    goes through the normal soft-delete scope, so an evaluation shows "deleted
#    user" and the invoice still adds up.
# 3. `billable` is FROZEN, not referenced. Role#billable is editable, so
#    reconstructing the past through today's role state would compute the wrong
#    number -- the same reason an invoice copies a price instead of pointing at
#    one.
class CreateSeatEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :seat_events, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true, index: false

      # Provenance only -- deliberately NOT references/FKs, see header.
      t.uuid :organisation_id, null: false
      t.string :organisation_name, null: false
      t.uuid :user_id, null: false
      t.uuid :role_id

      t.string :event, null: false
      t.datetime :occurred_at, null: false

      # The role's billable flag AT THE TIME of the event (header, point 3).
      t.boolean :billable, null: false

      # Whether this membership counts as a seat AFTER this event -- the single
      # value a reconstruction reads. Deliberately "after", not "before", so the
      # rule is identical for all three event types: take the newest event per
      # (organisation_id, user_id) up to date X, and the seat counts if
      # `counted` is true. An event carrying the state BEFORE would have to be
      # interpreted differently per type, which is how off-by-one seat counts
      # are born.
      t.boolean :counted, null: false

      t.timestamps
    end

    # Read path: one account's history in order -- the snapshot job (T18) and
    # any period reconstruction walk exactly this.
    add_index :seat_events, %i[account_id occurred_at],
              name: 'idx_seat_events_account_occurred'
    # Read path: the timeline of ONE membership, which is what a reconstruction
    # groups by (the membership row itself may be long gone, so its id is not
    # available as a key). Named explicitly -- the generated name exceeds
    # Postgres' 63-char limit and would be replaced by an unreadable hash.
    add_index :seat_events, %i[organisation_id user_id occurred_at],
              name: 'idx_seat_events_membership_timeline'
  end
end
