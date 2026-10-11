# frozen_string_literal: true

# A chat gets an owner (assistant plan §5.1, cut S1).
#
# Nullable on purpose, and it stays nullable after the backfill: a ticket thread has
# no single owner and remains shared until S4, so "no owner" is a legitimate state and
# not a gap to be closed later with a NOT NULL.
#
# The backfill itself is NOT here (project rule: data migrations are a task, not a
# schema migration). It runs as `rake chats:backfill_owners` between this migration
# and the deploy that makes ChatPolicy read the column.
class AddUserToChats < ActiveRecord::Migration[8.0]
  def change
    add_reference :chats, :user, type: :uuid, foreign_key: true, index: true, null: true
  end
end
