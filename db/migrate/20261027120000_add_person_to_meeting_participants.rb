# frozen_string_literal: true

# A meeting participant may point to a row of the people directory (Person),
# so a contact without an account has its meetings too. Nothing writes it yet;
# linking comes in a later step. Deleting a person keeps the participant and
# its display name.
class AddPersonToMeetingParticipants < ActiveRecord::Migration[8.1]
  def change
    add_reference :meeting_participants, :person, type: :uuid, null: true, index: true,
                                                  foreign_key: { on_delete: :nullify }
  end
end
