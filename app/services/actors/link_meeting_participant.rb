# frozen_string_literal: true

# app/services/actors/link_meeting_participant.rb
#
# Links one participant of a meeting to the people directory, or unlinks it
# (S2b). Afterwards the person's lane lists the meeting and counts it for
# "Letzter Kontakt" (People::Contacts reads both keys).
#
# One key per participant: a member is linked by user_id (the path the meeting
# form already uses), a contact by person_id. The row of a FORMER member is a
# contact, as the directory shows it. A participant of someone with a
# membership here is linked through its account and is left alone; one whose
# membership was removed may be linked as a contact.
#
# The caller authorizes the meeting write (MeetingPolicy#update?). This actor
# resolves every id itself, so a raw id never reaches a column:
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
      # A member participant is linked by its account; the meeting form owns that.
      refuse!(:member_participant) if member_participant?

      return @participant.update!(person_id: nil) if @unlink

      link_to_entry(chosen_entry)
    end

    private

    attr_reader :current_user

    def organisation
      @meeting.organisation
    end

    def chosen_entry
      return created_entry if @new_person
      return directory.member_entry(@member_id) || refuse!(:not_found) if @member_id
      return directory.person_entry(@person_id) || refuse!(:not_found) if @person_id

      refuse!(:nothing_picked)
    end

    def link_to_entry(entry)
      if entry.member?
        refuse!(:member_already_participant) if taken_by_another?(entry.user.id)
        refuse!(:member_name_taken) if name_taken_by_another?(entry.user.display_name)
        @participant.update!(user_id: entry.user.id, person_id: nil)
      else
        @participant.update!(person_id: entry.person.id, user_id: nil)
      end
    rescue ActiveRecord::RecordNotUnique
      # The meeting lock runs two links one after the other, so the check above
      # sees the first. A writer that skips the lock still meets the unique index.
      refuse!(:member_already_participant)
    end

    # A participant of someone with a membership here, active or not. One whose
    # membership was removed is a name again (their row lost its account through
    # PersonLinkRelease): it may be linked as a contact, and its account goes.
    def member_participant?
      @participant.user_id.present? &&
        Membership.where(organisation: organisation, user_id: @participant.user_id).exists?
    end

    def taken_by_another?(user_id)
      @meeting.meeting_participants.where(user_id: user_id).where.not(id: @participant.id).exists?
    end

    # The meeting form labels a member chip with the member's profile name
    # (MeetingsController#meeting_participant_options); a second participant of
    # that name would make every later save of the meeting fail on its unique
    # name (SaveMeeting#guard_against_duplicates!).
    def name_taken_by_another?(name)
      @meeting.meeting_participants.where(normalized_name: PersonName.normalize(name))
              .where.not(id: @participant.id).exists?
    end

    def created_entry
      refuse!(:not_allowed) unless PersonPolicy.manage_allowed?(current_user, organisation)

      params = @new_person.to_h.symbolize_keys.slice(:name)
      result = Actors::SavePerson.call(organisation: organisation, params: params, current_user: current_user)
      raise ActorError.new(result.errors, code: :validation_failed) unless result.success?

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
