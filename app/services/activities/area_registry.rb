# frozen_string_literal: true

# Which permission area an ACTIVITY row belongs to (assistant plan §9a Befund 1,
# §13-11).
#
# Entry point: area_for
#
# ⚠️ Mapped by `key`, NOT by `trackable_type`, and that is the whole point. The
# plan sketched a type map next to ProjectRag::ContentAreaRegistry::AREA_BY_TYPE.
# Measured against the production table, that cannot work: there are four
# trackable types in total (Ticket, Project, TimeSessionGroup, Organisation), and
# `Project` carries note, document, meeting, member and permission events alike:
#
#   project.note_created · project.document_created · project.meeting_created
#   project.member_added · project.permission_changed · project.created
#
# A type map would put all of those in one bucket, i.e. exactly the distinction
# this gate exists to make. `Activity#set_key` composes the key as
# "<trackable_type.underscore>.<action>", so the key carries both halves and is
# the only column that can answer the question.
#
# The existing project feed already half-knew this: it matches meetings on the
# ACTION because they are tracked on the project
# (Organisations::Projects::ActivitiesController::MEETING_ACTIONS). This registry
# turns that special case into the rule.
#
# The inbox asks the same question about a notification whose subject is the
# project (Notification.area_for, Notification.readable, through
# .project_actions_by_area). Until 2026-10-08 it measured such a row by its type
# and let every reader of the project see it, ticket titles in the payload included.
#
# Sibling of ProjectRag::ContentAreaRegistry::AREA_BY_TYPE, deliberately NOT in
# that file: this is a different question (which event, not which record type)
# over a different column, and folding them together would produce one map that
# answers neither cleanly. Each points at the other.
module Activities
  class AreaRegistry
    # A row's gate is either a real ProjectPermission area, or PROJECT_LEVEL.
    #
    # PROJECT_LEVEL = "visible to anybody who may see this project at all" (any
    # area read). Decided 2026-08-26: a project being renamed is not the content
    # of any single area, and hiding it from someone who sees the project would
    # say less than the project's own page already says.
    PROJECT_LEVEL = :project

    AREA_BY_KEY = {
      # --- the ticket itself (TicketTrackable) --------------------------------
      'ticket.created' => :tickets,
      'ticket.updated' => :tickets,
      'ticket.deleted' => :tickets,
      'ticket.assigned' => :tickets,
      'ticket.unassigned' => :tickets,
      'ticket.status_changed' => :tickets,
      'ticket.priority_changed' => :tickets,
      'ticket.title_changed' => :tickets,
      'ticket.description_changed' => :tickets,
      'ticket.custom_attributes_changed' => :tickets,
      'ticket.post_added' => :tickets,
      'ticket.subscriber_added' => :tickets,
      'ticket.subscriber_removed' => :tickets,
      'ticket.moved' => :tickets,

      # --- tracked ON the project (ProjectTrackable) --------------------------
      # These are the rows a type map would have collapsed. Each one is gated by
      # the area of the object it is ABOUT, not by the project it hangs on.
      'project.ticket_created' => :tickets,
      'project.ticket_moved_in' => :tickets,
      'project.ticket_moved_out' => :tickets,
      'project.tickets_bulk_changed' => :tickets,
      'project.tickets_bulk_undone' => :tickets,
      'project.tickets_bulk_moved' => :tickets,
      'project.tickets_bulk_moved_in' => :tickets,
      'project.tickets_bulk_deleted' => :tickets,
      'project.note_created' => :notes,
      'project.document_created' => :documents,
      'project.meeting_created' => :meetings,
      'project.meeting_deleted' => :meetings,
      'project.chat_created' => :chats,
      'project.member_added' => :members,
      'project.member_removed' => :members,
      'project.permission_changed' => :members,
      # A smart folder is a saved view over tickets and time. :tickets is the
      # stricter of the two gates it could carry (there is no time area on
      # ProjectPermission at all, §2.4), so it is the one that applies.
      'project.smart_folder_created' => :tickets,
      # An imported codebase feeds the code-side of retrieval, whose permission
      # column is :documentation.
      'project.codebase_imported' => :documentation,
      # Saved views and the project record itself: project-level.
      'project.view_configuration_created' => PROJECT_LEVEL,
      'project.created' => PROJECT_LEVEL,
      'project.updated' => PROJECT_LEVEL,
      'project.deleted' => PROJECT_LEVEL
    }.freeze

    # Events that are NOT project-bound and therefore have no area to be gated by
    # (decided 2026-08-26: leave them out until somebody misses them).
    #
    #   time_session_group.*  billing runs; a billing spans projects, and the
    #                         all/own tier of TimeSessions::ViewingScope cannot
    #                         be asked about a row that belongs to no project.
    #   organisation.*        administration (AI package selected, AI activated).
    #                         Those belong in the AI protocol, not in a record of
    #                         what people worked on.
    IGNORED_PREFIXES = %w[time_session_group organisation].freeze

    # nil means "no rule", and every caller treats that as "drop the row"
    # (fail-closed). A new event type therefore disappears from the feed rather
    # than showing up ungated -- and the guard spec makes it visible while it is
    # still somebody's pull request.
    def self.area_for(key)
      AREA_BY_KEY[key.to_s]
    end

    def self.ignored?(key)
      IGNORED_PREFIXES.include?(key.to_s.split('.').first)
    end

    # Keys grouped by their gate, which is the shape the query builder needs: one
    # WHERE clause per area rather than one per key.
    def self.keys_by_area
      @keys_by_area ||= AREA_BY_KEY.group_by { |_key, area| area }
                                   .transform_values { |pairs| pairs.map(&:first).freeze }
                                   .freeze
    end

    # The events tracked ON the project, by their gate, as ACTIONS (the key without
    # "project."): a notification about one has the project as its subject and keeps
    # only the action (payload['action']). An action missing here reaches no reader.
    def self.project_actions_by_area
      @project_actions_by_area ||= keys_by_area.each_with_object({}) do |(area, keys), map|
        actions = keys.filter_map { |key| key.delete_prefix('project.') if key.start_with?('project.') }
        map[area] = actions.freeze if actions.any?
      end.freeze
    end
  end
end
