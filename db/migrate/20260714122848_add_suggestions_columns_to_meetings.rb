# frozen_string_literal: true

# Slice 8: the ticket-suggestion run status pair on meetings — the exact Slice-4
# summary trio minus a content column (the "content" of a run is the suggestion
# rows in meeting_ticket_suggestions). flag = "a run is generating" (set by the
# controller on enqueue, cleared by the service); error holds the readable failure.
class AddSuggestionsColumnsToMeetings < ActiveRecord::Migration[8.0]
  def change
    change_table :meetings, bulk: true do |t|
      t.boolean :suggestions_creation_flag, null: false, default: false
      t.text :suggestions_creation_error, null: false, default: ''
    end
  end
end
