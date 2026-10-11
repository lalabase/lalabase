# frozen_string_literal: true

# Turns a chat into a ticket-scoped thread (Ticket-Chat, Plan §8-1 Option C).
# Nullable: NULL means "project chat" (the existing behaviour), so no backfill is
# needed. The DB FK stays plain (no on_delete) — ticket deletion is handled at the
# app level via `Ticket has_many :chats, dependent: :destroy`, mirroring how
# posts/ticket_documents already work (D13).
#
# The index is a PARTIAL UNIQUE index: at most one thread per ticket (D2/D4), while
# project chats (ticket_id IS NULL) stay unconstrained. A race on the first pill
# click surfaces as RecordNotUnique, which the controller's find_or_create retries.
# `index: false` on add_reference avoids a redundant non-unique index on the same
# column (the partial unique index already serves ticket_id = ? lookups).
class AddTicketToChats < ActiveRecord::Migration[8.0]
  def change
    add_reference :chats, :ticket, type: :uuid, null: true, index: false,
                                    foreign_key: { to_table: :tickets }

    add_index :chats, :ticket_id, unique: true,
                                  where: 'ticket_id IS NOT NULL',
                                  name: 'index_chats_on_ticket_id'
  end
end
