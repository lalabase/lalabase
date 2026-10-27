# frozen_string_literal: true

# The value one line of the link dialog sends (S2b): "person:<id>" for a row of
# the people directory, "member:<id>" for a member (by account, also one
# without a row), "new" for a person created in the same step. The dialog
# writes it (value_for), the controller reads it, and so does the dialog when
# it draws a refused pick again (parse). The format lives here once, so the
# writer and the two readers cannot drift apart.
#
# Entry point: parse
module Meetings
  module ParticipantLinkChoice
    NEW_PERSON = 'new'
    # Only a canonical id counts: the controller hands the id to the actor,
    # which looks it up in the writer's directory.
    PICK = /\A(?<kind>person|member):(?<id>\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z/

    # kind: :person, :member or :new_person; id: nil for :new_person.
    Choice = Data.define(:kind, :id)

    def self.value_for(entry)
      entry.member? ? "member:#{entry.user.id}" : "person:#{entry.person.id}"
    end

    # The choice a value names, or nil for anything else (nothing picked, a
    # tampered value, a nested parameter).
    def self.parse(value)
      return Choice.new(kind: :new_person, id: nil) if value == NEW_PERSON

      match = PICK.match(value.to_s)
      Choice.new(kind: match[:kind].to_sym, id: match[:id]) if match
    end
  end
end
