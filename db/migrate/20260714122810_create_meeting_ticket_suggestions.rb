# frozen_string_literal: true

# Slice 8: persisted AI ticket suggestions derived from a meeting's source
# (transcript/notes, E22). status = open/accepted/dismissed (default open):
# accepting one creates a real Ticket (created_ticket, audit) plus a Meeting→Ticket
# reference, dismissing just closes it. A run REPLACES the open rows; accepted and
# dismissed rows stay as history — hence the (meeting_id, status) index.
#
# similar_ticket is the server-side similarity hint (a nearest existing ticket in
# the same project). Both ticket FKs nullify: deleting either the matched or the
# created ticket must never cascade into the suggestion history.
class CreateMeetingTicketSuggestions < ActiveRecord::Migration[8.0]
  def change
    create_table :meeting_ticket_suggestions, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true, index: false
      # The (meeting_id, status) index below covers meeting-scoped lookups (leftmost
      # prefix), so no separate meeting_id index.
      t.references :meeting, type: :uuid, null: false, foreign_key: true, index: false
      t.string :title, null: false
      t.text :description, null: false, default: ''
      # Similarity hint (E22) + created-ticket audit — both nullify so the suggestion
      # outlives a ticket deletion. Indexes kept (references default) so the
      # ON DELETE SET NULL scan on a ticket delete stays cheap.
      t.references :similar_ticket, type: :uuid, null: true,
                                    foreign_key: { to_table: :tickets, on_delete: :nullify }
      t.references :created_ticket, type: :uuid, null: true,
                                    foreign_key: { to_table: :tickets, on_delete: :nullify }
      # Enum open(0)/accepted(1)/dismissed(2); new suggestions start open.
      t.integer :status, null: false, default: 0
      t.timestamps
    end

    add_index :meeting_ticket_suggestions, :organisation_id
    add_index :meeting_ticket_suggestions, %i[meeting_id status]
  end
end
