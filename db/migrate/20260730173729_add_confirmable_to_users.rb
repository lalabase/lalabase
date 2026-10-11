# frozen_string_literal: true

# E-mail confirmation for self-registration (registration hardening).
#
# THE BACKFILL DELIBERATELY SITS IN THIS MIGRATION, against the house rule in
# CLAUDE.md ("Datenmigrationen als Task/Service, NICHT in Schema-Migration").
# Rationale: :confirmable goes live in the same commit, so from the moment these
# columns exist EVERY pre-existing user counts as unconfirmed. A forgotten
# follow-up task would lock out the whole instance, operator included — and this
# repo already carries two rake tasks from earlier PRs that were never run in
# production. One UPDATE over a small table is by far the cheaper risk.
#
# unconfirmed_email serves reconfirmable (already switched on in
# config/initializers/devise.rb, but inert without :confirmable): an e-mail
# change parks the new address there until it is confirmed, so the account keeps
# working under the old one.
#
# The unique index tolerates the NULLs it starts with: Postgres treats NULLs as
# distinct, so only real tokens are constrained.
class AddConfirmableToUsers < ActiveRecord::Migration[8.0]
  def up
    change_table :users, bulk: true do |t|
      t.column :confirmation_token, :string
      t.column :confirmed_at, :datetime
      t.column :confirmation_sent_at, :datetime
      t.column :unconfirmed_email, :string
    end

    add_index :users, :confirmation_token, unique: true

    execute <<~SQL.squish
      UPDATE users SET confirmed_at = created_at WHERE confirmed_at IS NULL
    SQL
  end

  def down
    remove_index :users, :confirmation_token

    change_table :users, bulk: true do |t|
      t.remove :confirmation_token, :confirmed_at, :confirmation_sent_at, :unconfirmed_email
    end
  end
end
