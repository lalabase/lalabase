# frozen_string_literal: true

# Adds the self-referential parent_id to tickets for one-level sub-tasks.
#
# on_delete: :nullify mirrors the app-level `dependent: :nullify` (Ticket model)
# so children are ORPHANED, never destroyed, on parent delete — across every
# delete path (Rails destroy, raw SQL, project/org cascade). Premise 4 of the
# sub-tasks design: silently destroying a child's logged time/comments would be
# data loss.
class AddParentToTickets < ActiveRecord::Migration[8.0]
  def change
    add_reference :tickets, :parent, type: :uuid, null: true, index: true,
                  foreign_key: { to_table: :tickets, on_delete: :nullify }
  end
end
