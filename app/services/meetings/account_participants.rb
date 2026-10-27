# frozen_string_literal: true

# Which participants of a meeting are linked through an account (S2b of the
# people directory). Their link belongs to the meeting form, which offers
# members by account; the link dialog leaves them alone. One owner for the
# rule, asked by the actor that writes (Actors::LinkMeetingParticipant refuses
# them) and by the participant row that offers the dialog
# (MeetingParticipantLinksHelper#meeting_participant_people hides its action).
#
# Entry point: include?
module Meetings
  class AccountParticipants
    def initialize(organisation:, participants:)
      @organisation = organisation
      @participants = participants
    end

    # True for a participant that is
    # * a member by user_id, with a membership here, ACTIVE OR NOT: a
    #   deactivated member keeps the account, and it comes back with the
    #   membership. Once the membership is removed, the participant is a name
    #   again (the dialog may link it to the row that keeps their meetings);
    # * a contact by person_id whose row belongs to an ACTIVE member now: the
    #   row was linked to a member after the participant was linked to it
    #   (SavePerson#assign_link, or a deactivated member came back). The
    #   participant is that member, and a writer who may not see the member
    #   must not be able to unlink or overwrite it. A row of a deactivated
    #   member is a contact, as the directory shows it, so linking to it
    #   stays possible.
    def include?(participant)
      ids.include?(participant.id)
    end

    private

    def ids
      @ids ||= @participants.select { |participant| through_account?(participant) }.to_set(&:id)
    end

    def through_account?(participant)
      if participant.user_id
        member_user_ids.include?(participant.user_id)
      elsif participant.person_id
        rows_of_active_members.include?(participant.person_id)
      else
        false
      end
    end

    def member_user_ids
      @member_user_ids ||= begin
        user_ids = @participants.filter_map(&:user_id)
        user_ids.empty? ? Set.new : Membership.where(organisation: @organisation, user_id: user_ids).pluck(:user_id).to_set
      end
    end

    def rows_of_active_members
      @rows_of_active_members ||= begin
        person_ids = @participants.filter_map(&:person_id)
        if person_ids.empty?
          Set.new
        else
          active_members = Membership.where(organisation: @organisation, active: true).select(:user_id)
          Person.where(organisation: @organisation, id: person_ids, user_id: active_members).pluck(:id).to_set
        end
      end
    end
  end
end
