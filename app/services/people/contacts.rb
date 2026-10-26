# frozen_string_literal: true

# Read object for the people directory (S2a): the meetings of a person and the
# last contact with people, both only as far as the viewer may read them.
#
# Entry point: meetings_for / last_contacts
module People
  # * A person's meetings are the meetings with a participant that points to
  #   the person row (person_id) OR, for a member, to the account (user_id).
  #   A member without a row of their own has meetings through user_id alone.
  # * Readable means MeetingPolicy::Scope and TicketPolicy::Scope, the rules of
  #   "Alle Meetings" and the ticket list; no rule of its own next to them.
  # * The last contact (E3) is the newest readable meeting; for an active
  #   member also their own work on a readable ticket (created, changed,
  #   commented), whichever is newer. A comment the viewer may not read
  #   (Post.readable_by) does not count, nor does a bulk run (Activity.feed).
  # * #last_contacts answers a whole list in a fixed number of queries: one
  #   per kind (meetings by person, meetings by user, ticket work), one for the
  #   ticket numbers, plus the policy scopes.
  class Contacts
    # Ticket activity keys that count as own work, by kind (the words of the
    # lane: angelegt, geändert, kommentiert). Subscribing, assigning and
    # moving are not counted.
    TICKET_ACTIONS = {
      'created' => :created,
      'post_added' => :commented,
      'updated' => :changed,
      'title_changed' => :changed,
      'description_changed' => :changed,
      'status_changed' => :changed,
      'priority_changed' => :changed,
      'custom_attributes_changed' => :changed
    }.freeze

    # What a list row or the lane needs to know about the one contact shown.
    LastContact = Struct.new(:at, :kind, :meeting_title, :ticket_number, :action, keyword_init: true)

    # One entry of the directory: its person row, its account, and whether the
    # account is an active member (only then does ticket work count).
    Subject = Struct.new(:person_id, :user_id, :member, keyword_init: true)

    # The participant column a meeting lookup reads, by name; never interpolated
    # from a caller.
    PARTICIPANT_COLUMNS = {
      person: 'meeting_participants.person_id',
      user: 'meeting_participants.user_id'
    }.freeze

    def initialize(viewer:, organisation:)
      @viewer = viewer
      @organisation = organisation
    end

    # The readable meetings of a person row and/or an account, newest first.
    def meetings_for(person: nil, user: nil)
      user_id = user&.id || person&.user_id
      return Meeting.none if person.nil? && user_id.nil?

      participants = MeetingParticipant.none
      participants = participants.or(MeetingParticipant.where(person_id: person.id)) if person
      participants = participants.or(MeetingParticipant.where(user_id: user_id)) if user_id
      readable_meetings.where(id: participants.select(:meeting_id)).order(occurred_at: :desc, id: :desc)
    end

    # The last contact of each subject, in the order given (nil: none).
    def last_contacts(subjects)
      by_person = latest_meetings(:person, subjects.filter_map(&:person_id).uniq)
      by_user = latest_meetings(:user, subjects.filter_map(&:user_id).uniq)
      by_actor = latest_ticket_work(subjects.select(&:member).filter_map(&:user_id).uniq)
      subjects.map do |subject|
        candidates = [by_person[subject.person_id], by_user[subject.user_id]]
        candidates << by_actor[subject.user_id] if subject.member
        candidates.compact.max_by(&:at)
      end
    end

    private

    def readable_meetings
      @readable_meetings ||= MeetingPolicy::Scope.new(@viewer, Meeting).resolve
    end

    def readable_tickets
      @readable_tickets ||= TicketPolicy::Scope.new(@viewer, Ticket).resolve
    end

    # The newest readable meeting per person row or per account.
    def latest_meetings(key, ids)
      return {} if ids.empty?

      column = PARTICIPANT_COLUMNS.fetch(key)
      rows = MeetingParticipant.where(meeting_id: readable_meetings.select(:id))
                               .where(key == :person ? { person_id: ids } : { user_id: ids })
                               .joins(:meeting)
                               .select(Arel.sql("DISTINCT ON (#{column}) #{column} AS subject_id, " \
                                                'meetings.title AS meeting_title, meetings.occurred_at AS met_at'))
                               .order(Arel.sql("#{column}, meetings.occurred_at DESC, meetings.id DESC"))
      rows.to_h do |row|
        [row.subject_id, LastContact.new(at: row.met_at, kind: :meeting, meeting_title: row.meeting_title)]
      end
    end

    # The newest own work of each account on a readable ticket.
    def latest_ticket_work(user_ids)
      return {} if user_ids.empty?

      rows = own_ticket_work(user_ids)
             .select('DISTINCT ON (activities.actor_id) activities.actor_id, activities.trackable_id, ' \
                     'activities.action, activities.created_at')
             .order('activities.actor_id, activities.created_at DESC, activities.id DESC').to_a
      numbers = readable_tickets.where(id: rows.map(&:trackable_id)).pluck(:id, :number).to_h
      rows.to_h do |row|
        [row.actor_id, LastContact.new(at: row.created_at, kind: :ticket, action: TICKET_ACTIONS.fetch(row.action),
                                       ticket_number: numbers[row.trackable_id])]
      end
    end

    def own_ticket_work(user_ids)
      base = Activity.feed.where(actor_id: user_ids, trackable_type: 'Ticket', action: TICKET_ACTIONS.keys,
                                 trackable_id: readable_tickets.select(:id))
      readable_posts = Post.readable_by(@viewer, @organisation).select(:id)
      base.where.not(secondary_type: 'Post').or(base.where(secondary_type: nil))
          .or(base.where(secondary_type: 'Post', secondary_id: readable_posts))
    end
  end
end
