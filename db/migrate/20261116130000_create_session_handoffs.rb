# frozen_string_literal: true

# The login hand-off from the main host to an organisation's host
# (doc/org_subdomains_plan.md, S3). Each host keeps a session of its own; a person signs in
# on the main host, and a single-use row carries the session to one subdomain, bound to the
# browser that began it. Only digests are stored.
class CreateSessionHandoffs < ActiveRecord::Migration[8.1]
  def change
    create_table :session_handoffs, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :token_digest, null: false
      t.string :state_digest, null: false
      t.string :host, null: false
      t.text :path, null: false
      t.datetime :expires_at, null: false
      t.datetime :created_at, null: false
    end

    add_index :session_handoffs, :token_digest, unique: true
    add_index :session_handoffs, :expires_at
  end
end
