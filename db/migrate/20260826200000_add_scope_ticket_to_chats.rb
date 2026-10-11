# frozen_string_literal: true

# S4 T2 (assistant plan §7.3): the reference chip. A standing narrowing of an
# org-wide thread to ONE ticket, set by the button in the ticket's header and
# visible at the input field next to the project chip.
#
# NULL means "no ticket reference", the state every existing thread has today,
# hence no backfill. A set reference IMPLIES the ticket's project; the two chips
# are not independent narrowings.
#
# on_delete: :nullify like scope_project: a deleted ticket must not take a
# conversation with it. The thread widens back and the chip says so, because
# Tools::Scope resolves the column against the asker's reach rather than reading
# it as the answer.
class AddScopeTicketToChats < ActiveRecord::Migration[8.0]
  def change
    add_reference :chats, :scope_ticket, type: :uuid, null: true, foreign_key: { to_table: :tickets, on_delete: :nullify }, index: true
  end
end
