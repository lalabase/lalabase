# frozen_string_literal: true

# Per-user, per-org chat answer-style preference (Plan v1.5, §6.2). Two integer
# levels — technicality + length, each 1..3 — that turn the previously stateless
# regenerate pills into a persistent style the assistant carries into every
# answer. acts_as_tenant on organisation (so the same user can keep a different
# style per org).
class CreateChatStylePreferences < ActiveRecord::Migration[8.0]
  def change
    create_table :chat_style_preferences, id: :uuid do |t|
      # index: false — organisation_id is the leftmost column of the composite
      # unique index below, which already covers every lookup we make (Leftmost-
      # Prefix); a standalone organisation_id index would be redundant.
      #
      # FK mechanism is deliberately ASYMMETRIC (see Organisation/User models):
      #  - organisation_id: NO ACTION. Org deletion is Rails-driven via
      #    Organisation has_many :dependent => :destroy, which runs inside the
      #    org's own tenant, so the children are in scope. Matches house convention.
      #  - user_id: ON DELETE CASCADE. A user delete is inherently CROSS-tenant
      #    (a user spans many orgs). A Rails has_many :dependent on User would run
      #    through ChatStylePreference's acts_as_tenant default scope and only
      #    delete the CURRENT tenant's rows → a hard user.destroy with a tenant set
      #    raises InvalidForeignKey on the other orgs' rows. A DB-level cascade is
      #    tenant-independent, so a hard delete (e.g. GDPR purge) always cleans up.
      #    It never fires on the normal soft-delete path (SoftDeletable sets
      #    deleted_at, never calls #destroy), so soft-deleted users keep their style.
      t.references :organisation, type: :uuid, null: false, index: false,
                                  foreign_key: true
      # user_id keeps its own index (the composite is [organisation_id, user_id],
      # so user_id alone is otherwise uncovered).
      t.references :user, type: :uuid, null: false,
                          foreign_key: { on_delete: :cascade }
      # 1 = lay-friendly / brief … 3 = technical (file:line) / detailed.
      # Neutral 2/2 default (Plan §0: no role-derivation).
      t.integer :technicality, null: false, default: 2
      t.integer :length,       null: false, default: 2

      t.timestamps
    end

    # One style row per (org, user). The model mirrors this for friendly errors.
    add_index :chat_style_preferences, %i[organisation_id user_id], unique: true
  end
end
