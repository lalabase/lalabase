# frozen_string_literal: true

# The ONE meetings list (doc/meetings_uebersicht_vereinheitlichen_plan.md, "One
# list owner"): saved views, the filter bar's conditions, the search with its
# depth, sort and pages, over the meetings the reader may read. Two lists use
# it and differ only in their project, which the includer names in
# #meeting_list_project:
#
#   the project page       Organisations::MeetingsController   @project
#   "Alle Meetings"        Organisations::MeetingsOverviewController, and
#                          MeetingsController for a request with
#                          list_context=organisation (Meetings::ListState):
#                          a save in the lane of that page                nil
#
# #meeting_organisation_list? is the ONE question "which list?" for every
# stream, redirect and link that leads back to a list. Until 17.10.2026 the
# "+" of "Alle Meetings" asked a question of its own (context=overview_modal).
#
# A list shows the meeting views of its own project: a view without a project
# belongs to "Alle Meetings" and shows only there (decision 3 of the plan).
# Until 17.10.2026 a project page also showed every view without a project, and
# the overview had a list owner of its own with only search, a participant and a
# project select.
#
# The includer brings AdHocFilterable and Pageable; this module overrides
# AdHocFilterable#active_folder_record so that a view of another list does not
# open by address.
module MeetingList
  extend ActiveSupport::Concern

  included do
    helper_method :meeting_organisation_list?, :meeting_list_index_path, :meetings_overview_first_use?
  end

  private

  def meeting_organisation_list?
    meeting_list_project.nil?
  end

  # The address of this list, with the query given (its state, a meeting_id):
  # where a redirect, the lane's way back and its close lead.
  def meeting_list_index_path(query = {})
    project = meeting_list_project
    project ? organisation_project_meetings_path(@current_organisation, project, query) : organisation_meetings_path(@current_organisation, query)
  end

  # No readable meeting anywhere yet: "Alle Meetings" shows its first-time
  # state. Asked by both includers, the overview's list is rendered from both.
  def meetings_overview_first_use?
    return @meetings_overview_first_use if defined?(@meetings_overview_first_use)

    @meetings_overview_first_use = !policy_scope(Meeting).exists?
  end

  # Sets what the list head and the rows read (@meeting_smart_folders,
  # @active_smart_folder, @dissolver_result, @current_search_mode, @columns,
  # @pagy, @meeting_list_query) and answers the page of meetings on screen.
  def filtered_meetings
    @meeting_smart_folders = meeting_list_folders.order(:name)
    @active_smart_folder = active_folder_record
    @dissolver_result = dissolved_active_view if @active_smart_folder
    @current_search_mode = params[:search_mode] == 'title_only' ? 'title_only' : 'content'
    @columns = meeting_list_columns
    @meeting_list_query = Meetings::ListQuery.call(
      scope: meeting_list_scope, search: scalar_param(:search), search_mode: @current_search_mode,
      filters: list_filter_params, operators: list_filter_op_params,
      smart_folder: @active_smart_folder, apply_folder_rules: !edited_saved_view?, sort: nested_param(:sort)
    )
    # Every row of "Alle Meetings" names its project; a project page knows its own.
    rows = meeting_list_project ? @meeting_list_query : @meeting_list_query.preload(:project)
    @pagy, meetings = paginate(rows, overflow: :last_page)
    meetings
  end

  def active_folder_record
    return @active_folder_record if defined?(@active_folder_record)

    @active_folder_record = (meeting_list_folders.find_by(id: params[:smart_folder_id]) if params[:smart_folder_id].is_a?(String))
  end

  # The meeting views of this list: project_id = the list's project, or IS NULL
  # on "Alle Meetings" (where(project_id: nil) says the latter).
  def meeting_list_folders
    policy_scope(SmartFolder).where(target_object_type: 'Meeting', project_id: meeting_list_project&.id)
  end

  def meeting_list_scope
    project = meeting_list_project
    project ? policy_scope(project.meetings) : policy_scope(Meeting)
  end

  # The base view of this list: the reader's row of the project, or on "Alle
  # Meetings" the row without a project, which offers the column "Projekt" too.
  # A saved view brings its own list (Lists::ResolveColumns).
  def meeting_list_columns
    @view_configuration = ViewConfiguration.for_list(user: current_user, organisation: @current_organisation,
                                                     project: meeting_list_project, view_type: 'meetings')
    Lists::ResolveColumns.call(view_configuration: @view_configuration, smart_folder: @active_smart_folder)
  end

  # A search term is one string; any other shape is no search.
  def scalar_param(key)
    value = params[key]
    value if value.is_a?(String)
  end
end
