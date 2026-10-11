# frozen_string_literal: true

class Organisations::Projects::ActivitiesController < Organisations::BaseController
  include Pagy::Backend
  include ProjectController

  # Meeting activities are tracked on the project (trackable_type = 'Project')
  # and distinguished only by their action, so the "Meeting" object-type filter
  # matches on action instead of trackable_type.
  MEETING_ACTIONS = %w[meeting_created meeting_deleted].freeze
  KNOWLEDGE_AREAS = %i[notes documents meetings chats documentation].freeze
  ADMINISTRATION_AREAS = %i[members project].freeze
  TICKET_KEYS = (Activities::AreaRegistry.keys_by_area.fetch(:tickets, []) - ['project.smart_folder_created']).freeze
  KNOWLEDGE_KEYS = (KNOWLEDGE_AREAS.flat_map do |area|
    Activities::AreaRegistry.keys_by_area.fetch(area, [])
  end + ['project.smart_folder_created']).freeze
  DETAIL_FRAME_ID = 'ticket_display_frame'

  # Override ProjectController's authorize_project_access! with our own
  skip_before_action :authorize_project_access!
  before_action :authorize_activities

  # Skip policy scoping for activities, since we use custom queries
  after_action :skip_policy_scope, only: [:index]

  def index
    activities = fetch_project_activities
    set_selected_activity(activities)

    # Apply filters
    activities = apply_filters(activities)

    # Pagination with Pagy
    @pagy, @activities = pagy(activities, items: 50)

    respond_to do |format|
      format.html
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.update('activity-filters', partial: 'filter_section'),
          turbo_stream.update('activities-list', partial: 'activities_list')
        ]
      end
    end
  end

  private

  def set_selected_activity(activities)
    return if params[:activity_id].blank?

    @selected_activity = activities.find_by(id: params[:activity_id])
    @selected_detail_url = selected_detail_url(Activities::ProjectTarget.call(@selected_activity)) if @selected_activity
  end

  def selected_detail_url(target)
    route_options = { frame: 'content', frame_id: DETAIL_FRAME_ID }

    case target
    when Ticket
      organisation_project_ticket_path(@current_organisation, @project, target, **route_options)
    when Document
      organisation_project_document_path(@current_organisation, @project, target, **route_options)
    when Note
      organisation_project_note_path(@current_organisation, @project, target, **route_options)
    when Meeting
      organisation_project_meeting_path(@current_organisation, @project, target, **route_options)
    when TimeSession
      organisation_project_time_session_path(@current_organisation, @project, target, **route_options)
    end
  end

  def authorize_activities
    authorize @project, :view_activities?
  rescue Pundit::NotAuthorizedError
    redirect_to organisation_project_path(@current_organisation, @project),
                alert: t('flash.activities.no_view_permission')
  end

  # S3b (§9a Befund 1, §13-11): ONE gate, shared with the assistant's activity
  # tool. What stood here was an eight-way UNION over per-type id subqueries, and
  # measuring it against the real table showed why it had to go: six of the eight
  # types never occur as a trackable at all (Document, Note, Chat, SmartFolder,
  # TimeSession, ProjectPermission), while the rows that DO exist for those
  # subjects hang on the PROJECT and were therefore all visible to anybody who
  # passed view_activities? -- which only asks "may you read any area at all".
  #
  # Now every row is gated by the area of the event it describes
  # (Activities::AreaRegistry, keyed by `key` because trackable_type cannot tell
  # a note creation from a permission change), and a reader who may only see
  # notes stops seeing ticket history.
  def fetch_project_activities
    Activities::VisibleTo.call(
      organisation: @current_organisation,
      reach: Activities::ProjectReach.new(user: current_user, project: @project)
    ).includes(:actor, :trackable, :secondary)
  end

  def apply_filters(activities)
    activities = activities.where(actor_id: current_user.id) if params[:view] == 'mine'
    activities = filter_by_area(activities, 'tickets') if params[:view] == 'tickets'

    # Filter by action type
    activities = activities.where(action: params[:action_type]) if params[:action_type].present?

    # Filter by actor
    activities = activities.where(actor_id: params[:actor_id]) if params[:actor_id].present?

    # Filter by date. Invalid address-bar values are ignored instead of turning
    # a read-only list into a 500 response.
    date_from = parse_date(params[:date_from])
    date_to = parse_date(params[:date_to])
    activities = activities.where('activities.created_at >= ?', date_from.beginning_of_day) if date_from
    activities = activities.where('activities.created_at <= ?', date_to.end_of_day) if date_to

    activities = filter_by_area(activities, params[:area]) if params[:area].present?
    activities = filter_by_search(activities, params[:q]) if params[:q].present?

    # Filter by object type. "Meeting" is a pseudo-type: those activities are
    # stored on the project and identified by action, not trackable_type.
    if params[:trackable_type].present?
      activities = if params[:trackable_type] == 'Meeting'
                     activities.where(action: MEETING_ACTIONS)
                   else
                     activities.where(trackable_type: params[:trackable_type])
                   end
    end

    activities
  end

  def filter_by_area(activities, area)
    case area
    when 'tickets'
      activities.where(key: TICKET_KEYS)
    when 'knowledge'
      activities.where(key: KNOWLEDGE_KEYS)
    when 'times'
      activities.where(trackable_type: 'TimeSession')
    when 'administration'
      activities.where(key: keys_for_areas(ADMINISTRATION_AREAS))
    else
      activities
    end
  end

  def keys_for_areas(areas)
    areas.flat_map { |area| Activities::AreaRegistry.keys_by_area.fetch(area, []) }
  end

  def filter_by_search(activities, query)
    term = query.to_s.strip
    return activities if term.blank?

    pattern = "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
    ticket_term = term.delete_prefix('#')
    matching_tickets = Ticket.where(project_id: @project.id)
                             .where('tickets.title ILIKE :pattern OR CAST(tickets.number AS TEXT) ILIKE :number',
                                    pattern:, number: "%#{ActiveRecord::Base.sanitize_sql_like(ticket_term)}%")
                             .select(:id)

    activities.where(
      <<~SQL.squish,
        activities.action ILIKE :pattern OR
        activities.key ILIKE :pattern OR
        CAST(activities.parameters AS TEXT) ILIKE :pattern OR
        (activities.trackable_type = 'Ticket' AND activities.trackable_id IN (:ticket_ids)) OR
        (activities.secondary_type = 'Ticket' AND activities.secondary_id IN (:ticket_ids))
      SQL
      pattern:,
      ticket_ids: matching_tickets
    )
  end

  def parse_date(value)
    Date.iso8601(value.to_s) if value.present?
  rescue Date::Error
    nil
  end
end
