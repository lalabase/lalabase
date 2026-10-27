# frozen_string_literal: true

# The participant row of a meeting and its dialog "Mit Person verknüpfen" (S2b,
# Organisations::MeetingParticipantLinksController). The ids are a shared
# contract between the row, the dialog and the controller's streams: they live
# here once. The rules live elsewhere, so they can be tested without a page:
# who is linked through an account (Meetings::AccountParticipants), the lines of
# the dialog (Meetings::ParticipantLinkOptions), the value of a pick
# (Meetings::ParticipantLinkChoice), the entry of a participant
# (People::Directory#entry_for_participant).
module MeetingParticipantLinksHelper
  # What the row may show the viewer: whether they may link, and for each
  # participant the address of its person, or nil. Read once per row, from the
  # viewer's own directory, so a person they may not see stays plain text.
  ParticipantPeople = Struct.new(:can_link, :paths, :account_participants, keyword_init: true) do
    def path_for(participant)
      paths[participant.id]
    end

    # The dialog is for free names and contacts. A participant linked through
    # an account belongs to the meeting form.
    def linkable?(participant)
      can_link && !account_participants.include?(participant)
    end
  end

  # The chips of one meeting's participants (meeting page and the panel beside a
  # ticket); a link or an unlink redraws them, never the dialog frame beside them.
  def meeting_participant_chips_id(meeting)
    dom_id(meeting, :participants)
  end

  # The frame the dialog loads into, one per meeting, inside the row. By the
  # meeting's id, not the record: the answer for a meeting that is gone from
  # this project has only the id of its route.
  def participant_link_modal_id(meeting_id)
    "meeting-participant-link-modal-#{meeting_id}"
  end

  # One opening of the dialog: a refused save replaces exactly it, a save
  # removes it, a late answer to a dialog closed meanwhile finds nothing.
  def participant_link_modal_instance_id(meeting_id, token)
    "#{participant_link_modal_id(meeting_id)}-#{token}"
  end

  # The list of the dialog, reloaded by its search.
  def participant_link_results_id(participant)
    "meeting-participant-link-results-#{participant.id}"
  end

  # The button that opened the dialog: the focus goes back to it.
  def participant_link_trigger_id(participant)
    "meeting-participant-link-trigger-#{participant.id}"
  end

  def meeting_participant_people(meeting, participants)
    accounts = Meetings::AccountParticipants.new(organisation: current_organisation, participants: participants)
    sees_people = PersonPolicy.view_allowed?(current_user, current_organisation)
    # Without view_people: no person links, no link action.
    return ParticipantPeople.new(can_link: false, paths: {}, account_participants: accounts) unless sees_people

    directory = People::Directory.new(viewer: current_user, organisation: current_organisation)
    paths = {}
    participants.each do |participant|
      entry = directory.entry_for_participant(participant)
      paths[participant.id] = person_entry_path(entry) if entry
    end
    ParticipantPeople.new(can_link: policy(meeting).link_participants?, paths: paths, account_participants: accounts)
  end

  # The person page of a directory entry: its row, or a member without one.
  def person_entry_path(entry)
    selection = entry.person ? { person_id: entry.person.id } : { member_id: entry.user.id }
    organisation_people_path(current_organisation, selection)
  end

  # The lines of the dialog (Meetings::ParticipantLinkOptions), from the
  # viewer's directory.
  def participant_link_options(participant, query, limit:, choice: nil)
    Meetings::ParticipantLinkOptions.new(viewer: current_user, organisation: current_organisation,
                                         participant: participant, query: query, limit: limit,
                                         choice: choice).lines
  end

  # The name of the person a participant is linked to, or nil when the viewer
  # may not see that person: the dialog then says only that a link exists.
  def participant_link_linked_name(participant)
    entry = People::Directory.new(viewer: current_user, organisation: current_organisation)
                             .person_entry(participant.person_id)
    entry && person_display_name(person: entry.person, user: (entry.user if entry.member?))
  end

  # The name a new person starts with: the participant's, without a note in
  # brackets ("J. Weber (Hoster)" -> "J. Weber"). A name that is only a note
  # stays as it is, so the field is never empty.
  def participant_link_new_name(participant)
    PersonName.without_note(participant.display_name).presence || participant.display_name
  end
end
