# frozen_string_literal: true

# The participant row of a meeting and its dialog "Mit Person verknüpfen" (S2b,
# Organisations::MeetingParticipantLinksController). The ids are a shared
# contract between the row, the dialog and the controller's streams: they live
# here once.
module MeetingParticipantLinksHelper
  # What the row may show the viewer: whether they may link, and for each
  # participant the address of its person, or nil. Read once per row, from the
  # viewer's own directory, so a person they may not see stays plain text.
  ParticipantPeople = Struct.new(:can_link, :paths, keyword_init: true) do
    def path_for(participant)
      paths[participant.id]
    end
  end

  # The row of one meeting's participants (meeting page and the panel beside a
  # ticket); a link or an unlink redraws it.
  def meeting_participants_row_id(meeting)
    dom_id(meeting, :participants)
  end

  # The frame the dialog loads into, one per meeting, inside the row.
  def participant_link_modal_id(meeting)
    "meeting-participant-link-modal-#{meeting.id}"
  end

  # One opening of the dialog: a refused save replaces exactly it, a save
  # removes it, a late answer to a dialog closed meanwhile finds nothing.
  def participant_link_modal_instance_id(meeting, token)
    "#{participant_link_modal_id(meeting)}-#{token}"
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
    return ParticipantPeople.new(can_link: false, paths: {}) unless PersonPolicy.view_allowed?(current_user, current_organisation)

    directory = People::Directory.new(viewer: current_user, organisation: current_organisation)
    paths = participants.each_with_object({}) do |participant, found|
      entry = participant_directory_entry(directory, participant)
      found[participant.id] = person_entry_path(entry) if entry
    end
    ParticipantPeople.new(can_link: policy(meeting).update?, paths: paths)
  end

  # The person page of a directory entry: its row, or a member without one.
  def person_entry_path(entry)
    selection = entry.person ? { person_id: entry.person.id } : { member_id: entry.user.id }
    organisation_people_path(current_organisation, selection)
  end

  # The lines of the dialog: the suggestions (E6) first, marked, then the
  # people matching the search, at most limit of them. A pick sent back after a
  # refusal (choice) stays in the list, wherever the search had found it.
  def participant_link_options(participant, query, limit:, choice: nil)
    directory = People::Directory.new(viewer: current_user, organisation: current_organisation, query: query)
    suggested = query.blank? ? directory.suggestions_for(participant.display_name) : []
    others = (directory.candidates - suggested).first(limit)
    picked = participant_link_chosen_entry(directory, choice)
    others.unshift(picked) if picked && !suggested.include?(picked) && !others.include?(picked)
    suggested.map { |entry| [entry, true] } + others.map { |entry| [entry, false] }
  end

  # The value a line of the dialog sends: a member by account, a contact by row.
  def participant_link_choice(entry)
    entry.member? ? "member:#{entry.user.id}" : "person:#{entry.person.id}"
  end

  # The line under a name in the dialog, as in the people list: function and
  # company of the row, else a member's email.
  def participant_link_detail(entry)
    [entry.person&.function, entry.person&.company].compact_blank.join(' · ').presence ||
      (entry.user&.email if entry.member?)
  end

  # The name a new person starts with: the participant's, without a note in
  # brackets ("J. Weber (Hoster)" -> "J. Weber").
  def participant_link_new_name(participant)
    participant.display_name.gsub(/\([^)]*\)/, ' ').squish.presence || participant.display_name
  end

  private

  # The entry a choice names, through the viewer's own directory, or nil.
  def participant_link_chosen_entry(directory, choice)
    kind, id = choice.to_s.split(':', 2)
    case kind
    when 'person' then directory.person_entry(id)
    when 'member' then directory.member_entry(id)
    end
  end

  def participant_directory_entry(directory, participant)
    if participant.user_id
      directory.member_entry(participant.user_id) || directory.former_member_entry(participant.user_id)
    elsif participant.person_id
      directory.person_entry(participant.person_id)
    end
  end
end
