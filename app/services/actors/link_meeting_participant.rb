# frozen_string_literal: true

# app/services/actors/link_meeting_participant.rb
#
# Links one participant of a meeting to the people directory, or unlinks it
# (S2b). Afterwards the person's lane lists the meeting and counts it for
# "Letzter Kontakt" (People::Contacts reads both keys).
#
# One key per participant (MeetingParticipant#one_key): a member is linked by
# user_id (the path the meeting form already uses), a contact by person_id. The
# row of a FORMER member is a contact, as the directory shows it. A participant
# linked through an account (Meetings::AccountParticipants) is left alone: the
# meeting form owns that link.
#
# The caller authorizes the meeting write (MeetingPolicy#link_participants?).
# This actor resolves every id itself, so a raw id never reaches a column:
# * the meeting under its row lock (Meeting#lock_in_project!): a meeting moved
#   out of the authorized project is gone, as is a participant of another one;
# * the person or member through the writer's own directory (People::Directory:
#   PersonPolicy::Scope and MembershipPolicy::Scope, nothing without
#   view_people);
# * a new person through Actors::SavePerson in the same transaction, only with
#   manage_people.
# No activity: a link carries no personal data worth a history line.
module Actors
  class LinkMeetingParticipant < BaseActor
    def initialize(meeting:, project:, participant_id:, current_user:, person_id: nil, member_id: nil,
                   new_person: nil, unlink: false)
      super()
      @meeting = meeting
      @project = project
      @participant_id = participant_id
      @current_user = current_user
      @person_id = person_id.presence
      @member_id = member_id.presence
      @new_person = new_person
      @unlink = unlink
    end

    def record
      @participant
    end

    def perform
      refuse!(:not_found) unless @meeting.lock_in_project!(@project.id)

      # The row lock too: the claim (Actors::ClaimMeetingParticipants) writes
      # participants without the meeting lock.
      @participant = @meeting.meeting_participants.lock.find_by(id: @participant_id)
      refuse!(:not_found) if @participant.nil?
      refuse!(:member_participant) if linked_through_account?

      if @unlink
        @participant.update!(person_id: nil)
      else
        link_participant_to(chosen_entry)
      end
    end

    private

    attr_reader :current_user

    def organisation
      @meeting.organisation
    end

    def linked_through_account?
      Meetings::AccountParticipants.new(organisation: organisation, participants: [@participant])
                                   .include?(@participant)
    end

    def chosen_entry
      return created_entry if @new_person

      refuse!(:nothing_picked) if @member_id.nil? && @person_id.nil?

      entry = @member_id ? directory.member_entry(@member_id) : directory.person_entry(@person_id)
      # Someone the writer may not see is no one: the same answer as a wrong id.
      refuse!(:not_found) if entry.nil?
      entry
    end

    def link_participant_to(entry)
      if entry.member?
        link_member(entry.user)
      else
        link_contact(entry.person)
      end
    end

    # A member is linked by account. The model validates "one member once per
    # meeting" too; this check comes first to answer with its own reason
    # instead of a validation message.
    def link_member(user)
      refuse!(:member_already_participant) if other_participants.exists?(user_id: user.id)
      refuse!(:member_name_taken) if name_shown_by_another?(user.display_name)

      @participant.update!(user_id: user.id, person_id: nil)
    rescue ActiveRecord::RecordNotUnique
      # Only a write that skips the meeting lock gets here (the lock runs two
      # links one after the other, so the check above sees the first). The
      # partial unique index (meeting_id, user_id) refuses it, with the same answer.
      refuse!(:member_already_participant)
    end

    # A contact is linked by its row, and one row only once per meeting: two
    # participants of one person would count the meeting twice in the person's
    # lane. No unique index backs this, because only this actor writes
    # person_id, and it runs under the meeting lock.
    def link_contact(person)
      refuse!(:person_already_participant) if other_participants.exists?(person_id: person.id)

      @participant.update!(person_id: person.id, user_id: nil)
    end

    def other_participants
      @meeting.meeting_participants.where.not(id: @participant.id)
    end

    # The meeting form shows a member under the profile name
    # (MeetingsController#meeting_participant_options) and refuses two
    # participants of one name (SaveMeeting#guard_against_duplicates!), so a
    # member whose name another participant shows would make every later save
    # of the meeting fail. Another participant shows its own name, or, when it
    # is a member, that member's profile name: both count. That is stricter
    # than the form in one rare case (a member outside the project, which the
    # form shows under its own name), and a refusal there is harmless.
    def name_shown_by_another?(name)
      wanted = PersonName.normalize(name)
      other_participants.includes(:user).any? do |other|
        other.normalized_name == wanted || (other.user && PersonName.normalize(other.user.display_name) == wanted)
      end
    end

    def created_entry
      refuse!(:not_allowed) unless PersonPolicy.manage_allowed?(current_user, organisation)

      # The dialog sends a name only; everything else is the person page's.
      params = @new_person.to_h.symbolize_keys.slice(:name)
      result = Actors::SavePerson.call(organisation: organisation, params: params, current_user: current_user)
      # Its own code: a stale or an internal failure of SavePerson is no
      # validation failure, and the controller answers our own failure with 500.
      raise ActorError.new(result.errors, code: result.code) unless result.success?

      People::Directory::Entry.new(kind: :contact, person: result.resource)
    end

    def directory
      @directory ||= People::Directory.new(viewer: current_user, organisation: organisation)
    end

    def refuse!(code)
      raise ActorError.new(I18n.t("services.actors.link_meeting_participant.#{code}"), code: code)
    end
  end
end
