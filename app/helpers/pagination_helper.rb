# frozen_string_literal: true

# Extracts pagination logic from views into testable helper methods.
# Used by _pagination_nav.html.erb and _pagination_nav_compact.html.erb.
module PaginationHelper
  FRAME_IDS = {
    'tickets' => 'tickets_list_frame',
    'time_sessions' => 'time_sessions_list_frame',
    'knowledge' => 'knowledge_results',
    'smart_folders' => 'smart-folders-list'
  }.freeze

  ITEMS_OPTIONS_COMPACT = [10, 20, 50].freeze
  ITEMS_OPTIONS_FULL    = [5, 10, 20, 50].freeze

  # Computes the display text for the pagination info, e.g. "1 – 20 of 36".
  def pagination_info_text(pagy)
    return nil if pagy.count.zero?

    display_from = pagy.from
    display_to   = pagy.to

    # Fallback: if pagy.from/to are unexpected, compute manually
    display_from = (pagy.page - 1) * pagy.limit + 1 if display_from.nil? || display_from < 1
    display_to = [pagy.page * pagy.limit, pagy.count].min if display_to.nil? || display_to < 1

    "#{display_from} – #{display_to} #{t('views.shared.pagination.of')} #{pagy.count}"
  end

  # Determines the Turbo Frame ID based on the controller or an explicit parameter.
  def pagination_frame_id(frame_id: nil)
    return frame_id if frame_id.present?

    FRAME_IDS[controller_name] || '_top'
  end

  # Determines the frame ID for the items-per-page dropdown.
  # For tickets: if a ticket is selected → reload only the list,
  # otherwise → the whole page (_top).
  def pagination_items_frame(frame_id:, selected_object: nil)
    if controller_name == 'tickets'
      has_selected = selected_object.present? || params[:ticket_id].present? || action_name == 'show'
      has_selected ? 'tickets_list_frame' : '_top'
    else
      frame_id
    end
  end

  # Builds the URL for a pagination page (prev/next).
  def pagination_page_url(_pagy, page, organisation: nil, project: nil, sort_params: {}, smart_folder_id: nil)
    return '#' unless page

    base = pagination_base_path(organisation: organisation, project: project)
    query = pagination_query_params(sort_params: sort_params, smart_folder_id: smart_folder_id)
    query[:page] = page

    # For tickets on show pages, generate absolute URLs (Turbo compatibility)
    base = "#{request.protocol}#{request.host_with_port}#{base}" if controller_name == 'tickets' && base.start_with?('/')

    with_query(base, query)
  end

  # Builds the URL for an items-per-page option.
  def pagination_items_url(items_count, organisation: nil, project: nil, sort_params: {}, smart_folder_id: nil)
    base = pagination_base_path(organisation: organisation, project: project)
    query = pagination_query_params(sort_params: sort_params, smart_folder_id: smart_folder_id)
    query[:items] = items_count
    query.delete(:page)

    with_query(base, query)
  end

  private

  # A base may already carry a query: the time list address takes its project
  # filter there (time_list_path). Then the join is "&", never a second "?",
  # which turned "...?project_id_filter=P?items=20" into a filter on a project
  # id of "P?items=20" (Zweitreview of #675).
  def with_query(base, query)
    "#{base}#{base.include?('?') ? '&' : '?'}#{query.to_query}"
  end

  # Determines the base path depending on the controller context.
  def pagination_base_path(organisation: nil, project: nil)
    org = organisation || @current_organisation || @organisation
    proj = project || @project

    case controller_name
    when 'tickets'
      pagination_tickets_base_path(org, proj)
    when 'time_sessions'
      pagination_time_sessions_base_path(org, proj)
    when 'meetings'
      org && proj ? organisation_project_meetings_path(org, proj) : request_base_path
    when 'notes'
      org && proj ? organisation_project_notes_path(org, proj) : request_base_path
    when 'documents'
      org && proj ? organisation_project_documents_path(org, proj) : request_base_path
    else
      request_base_path
    end
  end

  def pagination_tickets_base_path(org, proj)
    org_id = params[:organisation_id] || org&.id
    proj_id = params[:project_id] || proj&.id

    if org_id && proj_id
      "/org/#{org_id}/projects/#{proj_id}/tickets"
    elsif request.path =~ %r{/org/([^/]+)/projects/([^/]+)}
      "/org/#{::Regexp.last_match(1)}/projects/#{::Regexp.last_match(2)}/tickets"
    else
      path = request_base_path
      path.sub(%r{/tickets/[^/]+$}, '/tickets')
    end
  end

  def pagination_time_sessions_base_path(org, proj)
    return request_base_path unless org

    # One list; a project is a filter on it (doc/zeiten_eine_liste_plan.md).
    time_list_path(org, project: proj)
  end

  # Collects query parameters for pagination URLs.
  # Passes through ALL current query parameters (preserves filter state on page/items change),
  # only removes the 'page' param (pagination is set by the caller).
  def pagination_query_params(sort_params: {}, smart_folder_id: nil)
    url_params = (controller_name == 'meetings' ? meeting_list_state.merge(params.permit(:meeting_id, :new).to_h) : request.query_parameters.deep_dup).with_indifferent_access
    url_params.delete(:page)

    url_params[:smart_folder_id] = smart_folder_id if smart_folder_id.present?
    url_params[:filter] = params[:filter].to_unsafe_h if params[:filter].respond_to?(:to_unsafe_h)

    if sort_params.present?
      clean = sort_params.dup
      clean.delete(:project_id) if controller_name == 'tickets'
      url_params.merge!(clean)
    end

    url_params
  end

  # Cleaned-up base path from the current request.
  def request_base_path
    path = (request.path_info || request.path).split('?').first
    path.gsub(%r{/undefined$}, '')
  end
end
