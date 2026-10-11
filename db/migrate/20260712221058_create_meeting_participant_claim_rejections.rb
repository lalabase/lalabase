# frozen_string_literal: true

# Nachtrag (Teilnehmer-Claim): remembers a Meetings-writer's decision that an
# external participant name does NOT belong to a given org member, so the live
# claim hint stops nagging for real name doppelgängers. Keyed per
# (organisation, user, normalized_name); the user FK cascades because without the
# target user the rejection is gegenstandslos.
class CreateMeetingParticipantClaimRejections < ActiveRecord::Migration[8.0]
  def change
    create_table :meeting_participant_claim_rejections, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      # organisation_id leans on the composite unique index below (leftmost prefix).
      t.references :organisation, type: :uuid, null: false, foreign_key: true, index: false
      # Without the org member the rejection is meaningless → cascade delete.
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :normalized_name, null: false
      t.timestamps
    end

    # One rejection per (org, member, name): backs the reject action's
    # find_or_create_by so re-rejecting is idempotent, not a duplicate row.
    # Explicit name: the default would exceed PostgreSQL's 63-char identifier limit.
    add_index :meeting_participant_claim_rejections,
              %i[organisation_id user_id normalized_name],
              unique: true,
              name: 'idx_mp_claim_rejections_org_user_name'
  end
end
