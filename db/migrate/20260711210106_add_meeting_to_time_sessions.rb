# frozen_string_literal: true

class AddMeetingToTimeSessions < ActiveRecord::Migration[8.0]
  # Gespräche Slice 2: a TimeSession's subject may be a Ticket OR a Meeting, never
  # both. A dedicated nullable meeting_id column (NOT polymorphic — plan decision 2:
  # billing hangs off the project, FK integrity stays) plus a check constraint that
  # enforces the XOR. Meeting deletion nulls meeting_id (on_delete: :nullify, plan
  # decision 7) so a billed/grouped session never rides along on a meeting delete.
  # All existing sessions have meeting_id NULL, so the constraint holds immediately —
  # no backfill.
  def change
    add_reference :time_sessions, :meeting, type: :uuid, null: true, index: true,
                  foreign_key: { to_table: :meetings, on_delete: :nullify }

    add_check_constraint :time_sessions,
                         'NOT (ticket_id IS NOT NULL AND meeting_id IS NOT NULL)',
                         name: 'time_sessions_single_subject'
  end
end
