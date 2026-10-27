# frozen_string_literal: true

# One key per meeting participant: a member by user_id, a contact of the people
# directory by person_id, never both (MeetingParticipant#one_key holds the same
# rule for writes through the model). Three writers clear the other key by hand;
# this constraint makes a writer that forgets fail loudly, also one that writes
# past the model (update_all, a console fix).
#
# Safe to add in one step: until the link dialog (S2b) nothing wrote person_id,
# so no row carries both keys, and the table is small enough for the short
# lock of the validating ALTER TABLE.
class AddOneKeyCheckToMeetingParticipants < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :meeting_participants, 'num_nonnulls(user_id, person_id) <= 1',
                         name: 'meeting_participants_one_key'
  end
end
