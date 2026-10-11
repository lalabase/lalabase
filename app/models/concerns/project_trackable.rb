# frozen_string_literal: true

module ProjectTrackable
  extend ActiveSupport::Concern

  included do
    include Trackable

    # Callbacks for specific project events
    # Most events are tracked directly in the controllers
  end

  # Specific activity-tracking methods for projects

  # Team & permissions
  def track_member_added(user, permission_details = {})
    create_activity(
      action: 'member_added',
      secondary: user,
      parameters: {
        user_name: user.full_name,
        user_email: user.email,
        tickets_access: permission_details[:tickets_access],
        notes_access: permission_details[:notes_access],
        documents_access: permission_details[:documents_access],
        chats_access: permission_details[:chats_access],
        documentation_access: permission_details[:documentation_access],
        meetings_access: permission_details[:meetings_access]
      }.compact
    )
  end

  def track_member_removed(user, reason = nil)
    create_activity(
      action: 'member_removed',
      secondary: user,
      parameters: {
        user_name: user.full_name,
        reason: reason
      }.compact
    )
  end

  def track_permission_changed(user, changes = {})
    create_activity(
      action: 'permission_changed',
      secondary: user,
      attribute_changes: changes,
      parameters: {
        user_name: user.full_name
      }
    )
  end

  # Tickets & work packages
  def track_ticket_created(ticket)
    # Ensure that the ticket is persisted
    return unless ticket.persisted?

    create_activity(
      action: 'ticket_created',
      secondary: ticket,
      parameters: {
        ticket_number: ticket.number,
        ticket_title: ticket.title,
        creator_name: ticket.creator&.full_name
      }.compact
    )
  end

  def track_ticket_moved_in(ticket, from_project)
    create_activity(
      action: 'ticket_moved_in',
      secondary: ticket,
      parameters: {
        ticket_number: ticket.number,
        ticket_title: ticket.title,
        from_project_name: from_project&.name,
        from_project_id: from_project&.id
      }.compact
    )
  end

  def track_ticket_moved_out(ticket, to_project)
    create_activity(
      action: 'ticket_moved_out',
      secondary: ticket,
      parameters: {
        ticket_number: ticket.number,
        ticket_title: ticket.title,
        to_project_name: to_project&.name,
        to_project_id: to_project&.id
      }.compact
    )
  end

  # A bulk change of several tickets (doc/ticket_bulk_edit_plan.md, D12): the
  # ONE feed line and the ONE event that notifies the followers of the changed
  # tickets, while the tickets' own activities carry the run id and stay out
  # of the feed. Numbers only, no names: the run record has the rest.
  def track_tickets_bulk_changed(run, describe: [])
    create_activity(
      action: 'tickets_bulk_changed',
      parameters: bulk_run_parameters(run, describe)
    )
  end

  def track_tickets_bulk_undone(run, describe: [])
    create_activity(
      action: 'tickets_bulk_undone',
      parameters: bulk_run_parameters(run, describe).merge(undo_of: run.undo_of_id)
    )
  end

  # A bulk move (slice 7): the source project's line notifies the followers,
  # the target project's line only tells its feed (skip_notifications), or the
  # same people would hear it twice.
  def track_tickets_bulk_moved(run, target:, describe: [])
    create_activity(
      action: 'tickets_bulk_moved',
      parameters: bulk_run_parameters(run, describe).merge(target: target.name, target_project_id: target.id)
    )
  end

  def track_tickets_bulk_moved_in(run, source:, describe: [])
    create_activity(
      action: 'tickets_bulk_moved_in',
      parameters: bulk_run_parameters(run, describe).merge(source: source.name, source_project_id: source.id,
                                                           skip_notifications: true)
    )
  end

  # A bulk delete (D15): the followers were read before the tickets went, and
  # ride along for the fanout, because a ticket takes its subscriptions with it.
  def track_tickets_bulk_deleted(run, follower_ids:, describe: [])
    create_activity(
      action: 'tickets_bulk_deleted',
      parameters: bulk_run_parameters(run, describe).merge(follower_ids: follower_ids,
                                                           numbers: run.ok_numbers.sort.first(10).map { |n| "##{n}" }.join(', '))
    )
  end

  def bulk_run_parameters(run, describe)
    ok = run.results.select { |_id, result| result['ok'] }
    {
      bulk_run_id: run.id,
      count: run.changed_count,
      failed: run.failed_count,
      changes: describe.join(', '),
      ticket_ids: ok.keys,
      ticket_numbers: ok.values.map { |result| result['number'] }.compact.first(10)
    }
  end

  # Documents & content
  def track_document_created(document)
    create_activity(
      action: 'document_created',
      secondary: document,
      parameters: {
        document_title: document.title,
        creator_name: document.creator&.full_name
      }.compact
    )
  end

  def track_note_created(note)
    create_activity(
      action: 'note_created',
      secondary: note,
      parameters: {
        note_title: note.title,
        creator_name: note.creator&.full_name
      }.compact
    )
  end

  def track_meeting_created(meeting)
    create_activity(
      action: 'meeting_created',
      secondary: meeting,
      parameters: {
        meeting_title: meeting.title,
        creator_name: meeting.creator&.full_name
      }.compact
    )
  end

  # No `secondary:` — the meeting row is gone when this fires (after_destroy_commit);
  # a polymorphic reference to a deleted record would dangle. Parameters carry the
  # audit facts instead (transcripts are PII: deletions must leave a trace).
  def track_meeting_deleted(meeting)
    create_activity(
      action: 'meeting_deleted',
      parameters: {
        meeting_title: meeting.title,
        occurred_at: meeting.occurred_at&.iso8601
      }.compact
    )
  end

  def track_smart_folder_created(smart_folder)
    create_activity(
      action: 'smart_folder_created',
      secondary: smart_folder,
      parameters: {
        folder_name: smart_folder.name,
        query_type: smart_folder.query_type
      }.compact
    )
  end

  def track_view_configuration_created(view_configuration)
    create_activity(
      action: 'view_configuration_created',
      secondary: view_configuration,
      parameters: {
        view_name: view_configuration.name,
        view_type: view_configuration.view_type
      }.compact
    )
  end

  # AI & Automation
  def track_chat_created(chat)
    create_activity(
      action: 'chat_created',
      secondary: chat,
      parameters: {
        chat_title: chat.title || 'Neuer Chat',
        creator_name: chat.user&.full_name
      }.compact
    )
  end

  def track_codebase_imported(import_details = {})
    create_activity(
      action: 'codebase_imported',
      parameters: {
        files_count: import_details[:files_count],
        total_size: import_details[:total_size],
        importer_name: import_details[:importer_name]
      }.compact
    )
  end

  private

  # Override of Trackable for specific project parameters
  def track_specific_changes(changed_attrs)
    # Track the remaining changes normally
    return unless changed_attrs.any?

    create_activity(
      action: 'updated',
      attribute_changes: changed_attrs,
      parameters: activity_parameters_for_update
    )
  end

  def activity_parameters_for_create
    {
      project_name: name,
      description: description
    }.compact
  end

  def activity_parameters_for_update
    {
      project_name: name
    }
  end

  def activity_parameters_for_delete
    {
      project_name: name,
      tickets_count: tickets.count,
      documents_count: documents.count,
      notes_count: notes.count
    }
  end

  # GDPR-compliant: do not store any PII in parameters
  # User data is referenced via associations (secondary)
  # Names are only for display and are automatically anonymized on user deletion
end
