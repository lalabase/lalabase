# frozen_string_literal: true

# Project-only furniture shared by the single-activity and collapsed-run rows.
# The ticket timeline leaves @project nil and keeps its compact, context-free row.
module ProjectActivityRow
  ACTIVITY_SELECTION_PARAMS = %w[activity_id].freeze
  ACTIVITY_DETAIL_FRAME = 'ticket_display_frame'

  def project_row?
    @project.present?
  end

  def project_target
    return unless project_row?

    Activities::ProjectTarget.call(representative_activity)
  end

  def project_ticket
    target = project_target
    target if target.is_a?(Ticket)
  end

  def project_actor_name
    actor = representative_activity.actor
    actor ? helpers.viewer_display_name(actor) : t('components.activity_timeline.defaults.system_actor')
  end

  def project_object_name
    target = project_target
    snapshot = project_object_snapshot
    return snapshot if snapshot.present?

    case target
    when Ticket
      "##{target.number} #{target.title}"
    when Document
      target.title.presence || t('components.activity_timeline.defaults.unknown_document')
    when Note, Meeting, Chat
      target.title
    when SmartFolder
      target.name
    when TimeSession
      target.respond_to?(:description) ? target.description.presence || target.class.model_name.human : target.class.model_name.human
    when Project
      target.name
    else
      representative_activity.trackable_display_name
    end
  end

  def project_object_snapshot
    activity = representative_activity
    params = activity.parameters || {}

    case activity.action
    when 'ticket_created', 'ticket_moved_in', 'ticket_moved_out'
      [params['ticket_number'].present? ? "##{params['ticket_number']}" : nil, params['ticket_title']].compact.join(' ')
    when 'document_added', 'document_created'
      params['document_title'] || params['document_name']
    when 'note_created'
      params['note_title']
    when 'chat_created'
      params['chat_title']
    when 'meeting_created', 'meeting_deleted', 'meeting_moved_in', 'meeting_moved_out'
      params['meeting_title']
    when 'smart_folder_created'
      params['folder_name']
    end
  end

  def project_row_path
    target = project_target
    organisation = @project&.organisation
    return unless target && organisation

    case target
    when Ticket
      helpers.organisation_project_ticket_path(organisation, @project, target)
    when Document
      helpers.organisation_project_knowledge_index_path(organisation, @project, type: 'document', document_id: target.id)
    when Note
      helpers.organisation_project_knowledge_index_path(organisation, @project, type: 'note', note_id: target.id)
    when Meeting
      helpers.organisation_project_meeting_path(organisation, @project, target)
    when TimeSession
      helpers.organisation_project_time_session_path(organisation, @project, target)
    end
  end

  # The href is the full-page fallback. Knowledge objects deliberately land on
  # their shared index there; the lane itself fetches the resource endpoint so
  # Turbo receives only that object's detail frame.
  def project_row_detail_path
    target = project_target
    organisation = @project&.organisation
    return unless target && organisation

    case target
    when Ticket
      helpers.organisation_project_ticket_path(organisation, @project, target)
    when Document
      helpers.organisation_project_document_path(organisation, @project, target)
    when Note
      helpers.organisation_project_note_path(organisation, @project, target)
    when Meeting
      helpers.organisation_project_meeting_path(organisation, @project, target)
    when TimeSession
      helpers.organisation_project_time_session_path(organisation, @project, target)
    end
  end

  def project_row_data
    return {} unless project_row_path && project_row_detail_path

    {
      controller: 'list-row',
      action: 'click->list-row#click',
      list_row_url_value: project_row_detail_path,
      list_row_id_value: representative_activity.id,
      list_row_param_value: ACTIVITY_SELECTION_PARAMS.first,
      list_row_params_value: ACTIVITY_SELECTION_PARAMS,
      list_row_frame_value: ACTIVITY_DETAIL_FRAME,
      activity_target_id: representative_activity.id
    }
  end

  def project_row_selected?
    helpers.params[:activity_id].to_s == representative_activity.id.to_s
  end

  def project_kind_icon
    action = representative_activity.action

    case action
    when 'assigned', 'unassigned', 'member_added', 'member_removed', 'permission_changed'
      'person'
    when 'title_changed', 'description_changed', 'updated', 'custom_attributes_changed',
         'tickets_bulk_changed', 'tickets_bulk_undone'
      'pencil'
    when 'post_added', 'comment_added', 'chat_created'
      'chat-left'
    when 'started', 'stopped', 'paused', 'resumed'
      'clock'
    when 'document_added', 'document_created', 'note_created', 'meeting_created', 'meeting_deleted', 'smart_folder_created'
      'file-earmark'
    else
      'arrow-repeat'
    end
  end

  def project_row_wrapper_classes
    'group border-b border-cream-200 transition-colors hover:bg-cream-100'
  end

  def project_row_link_classes
    'grid min-w-0 grid-cols-[22px_minmax(0,1fr)_auto] gap-x-3 px-3 py-2.5 ' \
      'cursor-pointer focus-visible:outline focus-visible:outline-2 focus-visible:outline-ink ' \
      "focus-visible:-outline-offset-2 #{'selected-row' if project_row_selected?}"
  end
end
