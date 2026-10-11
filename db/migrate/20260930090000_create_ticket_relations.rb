# frozen_string_literal: true

# Typed relations between two tickets of one organisation (doc/ticket_relations_plan.md,
# revision 4): blocks, relates_to, duplicates, precedes. One row per relation; the reverse
# direction ("blocked by", "follows") is derived on read and never stored as a second row.
# Projects may differ, organisations may not (checked by the model).
#
# Both ticket foreign keys cascade on delete, although the schema hardly does that anywhere
# else (ticket_documents, chats and time_sessions do not). On purpose: a relation without
# both ends is an edge without nodes and carries nothing, unlike an orphaned sub-task, which
# keeps its own time and comments (tickets.parent_id nullifies for that reason). The database
# is the truth and also holds for raw SQL; Ticket's `dependent: :delete_all` only saves
# loading the rows. No tombstone either: the user set the relation on purpose, and
# "blocks #47 (deleted)" helps no one.
#
# No creator_id on purpose: it would turn every row into personal data for the user data
# export (its registry guard matches the column name), for a value nothing shows.
#
# The relation_type integers are fixed (hash-form enum in TicketRelation). The partial unique
# index and the delay_days check spell them out; spec/architecture/ticket_relation_schema_guard_spec.rb
# compares both with the model.
class CreateTicketRelations < ActiveRecord::Migration[8.1]
  def change
    create_table :ticket_relations, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.references :source_ticket, type: :uuid, null: false, index: false,
                                   foreign_key: { to_table: :tickets, on_delete: :cascade }
      t.references :target_ticket, type: :uuid, null: false, index: false,
                                   foreign_key: { to_table: :tickets, on_delete: :cascade }
      t.integer :relation_type, null: false
      # Only for precedes (3). Stored and shown, never used to compute a date.
      t.integer :delay_days
      t.timestamps

      t.check_constraint 'source_ticket_id <> target_ticket_id', name: 'ticket_relations_not_self_referential'
      t.check_constraint 'delay_days IS NULL OR relation_type = 3', name: 'ticket_relations_delay_only_for_precedes'
    end

    add_index :ticket_relations, %i[source_ticket_id target_ticket_id relation_type],
              unique: true, name: 'index_ticket_relations_unique_edge'
    # One edge per unordered pair for relates_to (1) and duplicates (2),
    # TicketRelation::SINGLE_EDGE_TYPES. blocks and precedes are left to the cycle check.
    add_index :ticket_relations,
              'LEAST(source_ticket_id, target_ticket_id), GREATEST(source_ticket_id, target_ticket_id), relation_type',
              unique: true, where: 'relation_type IN (1, 2)', name: 'index_ticket_relations_single_edge_per_pair'
    # The two read paths: what waits on a ticket, and what a ticket holds up
    # (Tickets::Waiting, Tickets::CycleCheck).
    add_index :ticket_relations, %i[target_ticket_id relation_type], name: 'index_ticket_relations_on_target_and_type'
    add_index :ticket_relations, %i[source_ticket_id relation_type], name: 'index_ticket_relations_on_source_and_type'
  end
end
