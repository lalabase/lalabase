# frozen_string_literal: true

# app/controllers/concerns/object_list_controller.rb
module ObjectListController
  extend ActiveSupport::Concern

  included do
    include Sortable
    include Pageable
    include Searchable
    include AdHocFilterable

    before_action :set_project
    before_action :set_objects
    before_action :set_object, only: %i[show edit update destroy], if: :should_set_object?
    before_action :authorize_project_access
    before_action :set_smart_folders
  end

  # Default index action for object lists
  def index
    # Authorize the index action with Pundit (generic authorization for the class)
    authorize object_type.constantize

    # Set strict cache-control headers to avoid cache problems
    set_strict_no_cache_headers

    # Prevent Turbo Frame caching for pagination requests
    response.headers['Turbo-Cache-Control'] = 'no-cache' if turbo_frame_request? && params[:page].present?

    # Check whether a specific object should be displayed
    set_selected_object

    # Auto-pagination: if an object is selected and no page was given,
    # calculate the correct page for the selected object
    if @selected_object.present? && params[:page].blank? && !turbo_frame_request?
      calculate_and_redirect_to_object_page
      return
    end

    # Mobile details use full-page navigation; returning to their list must
    # preserve the page and every filter/sort parameter in the address.
    if @viewport_mode != 'mobile' && !turbo_frame_request? && params[:page].present? && params[:page] != '1' && @selected_object.blank?
      redirect_params = params.permit(:search, :search_mode, :sort, :items, :smart_folder_id).except(:page)
      redirect_to url_for(redirect_params) and return
    end

    # Sort and paginate the objects; the folder and the list filters are applied
    # by filtered_objects, the one owner of that pipeline.
    @pagy, @objects = paginate(filtered_objects)
    instance_variable_set("@#{object_type.downcase.pluralize}", @objects)

    # First check for the special Turbo-Stream HTML format
    if request.format.to_s.include?('turbo-stream')
      # Render the turbo stream template explicitly for turbo-stream.html format
      render turbo_stream: turbo_stream.replace(results_frame_id, partial: results_partial_path, locals: build_results_locals)
      return
    end

    # Default behavior for HTML format
    # Turbo will automatically extract the relevant frame content
    respond_to do |format|
      format.html { render_index_html }
      format.turbo_stream do
        respond_to_sort_and_paginate(@pagy, @objects, results_frame_id, results_partial_path, build_results_locals)
      end
      # Catch-all for any other format
      format.any { render_index_html }
    end
  end

  # Default implementation for the show action
  def show
    # Authorize the show action with Pundit
    authorize @object

    # Set strict cache-control headers to avoid cache problems
    set_strict_no_cache_headers
    response.headers['Turbo-Visit-Control'] = 'reload'

    # Special parameter frame=content for Turbo Frame requests
    if params[:frame] == 'content'
      # Add a timestamp to prevent browser caching
      @timestamp = Time.now.to_i

      # Set an extremely specific ETag to force a fresh response
      response.headers['ETag'] = "W/\"#{object_type.downcase}-show-#{@object.id}-#{@timestamp}\""

      # Render the show partial without wrapping it in a turbo-frame
      object_show_html = render_to_string(
        partial: object_show_partial,
        formats: [:html],
        locals: { object_type.downcase.to_sym => @object, timestamp: @timestamp }
      )

      render turbo_stream: [
        turbo_stream.update(detail_frame_id, html: object_show_html)
      ]
      return
    end

    respond_to do |format|
      format.turbo_stream do
        # Extract the smart folder ID from the params
        smart_folder_id = params[:smart_folder_id]

        streams = []

        # Replace the content of the detail frame
        streams << turbo_stream.update(
          detail_frame_id,
          partial: object_show_partial,
          locals: { object_type.downcase.to_sym => @object }
        )

        # If we are coming from an update action, update the row in the list
        # and show a success message
        if params[:after_update] == 'true'
          # Update the row in the list
          streams << turbo_stream.replace_all(
            "tr[data-#{object_type.downcase}-id='#{@object.id}']",
            partial: "organisations/#{object_type.downcase.pluralize}/#{object_type.downcase}_row",
            locals: {
              object_type.downcase.to_sym => @object,
              "selected_#{object_type.downcase}".to_sym => @object,
              smart_folder_id: smart_folder_id,
              preserve_layout: true # Ensures that columns like the tags column stay visible
            }
          )

          # Show flash message
          streams << turbo_stream.prepend(
            'flash',
            partial: 'layouts/flash',
            locals: { flash: { notice: t('flash.shared.object_updated', object: object_type) } }
          )
        end

        render turbo_stream: streams
      end
      format.html do
        if turbo_frame_request?
          render partial: object_show_partial, locals: { object_type.downcase.to_sym => @object }
        else
          # Instead of redirecting, we render the with_object view directly with the selected object
          @selected_object = @object
          @pagy, @objects = paginate(apply_list_filters(project_objects))
          instance_variable_set("@#{object_type.downcase.pluralize}", @objects)

          # Reload smart folders
          set_smart_folders

          render with_object_template || :with_object
        end
      end
    end
  end

  private

  # Determines whether set_object should be called
  # Can be overridden in concrete controllers
  def should_set_object?
    true
  end

  # Sets the project context
  def set_project
    # Eager load organization for NeoProjectNavigationComponent permissions
    @project = Project.includes(:organisation).find(params[:project_id])
    @current_project = @project
    touch_project_last_accessed(@project)
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = t('projects.not_found', default: 'Das angeforderte Projekt konnte nicht gefunden werden.')
    redirect_to organisation_projects_path(@current_organisation)
  end

  # Throttled touch of last_accessed_at on project_permission (max 1x/hour per user+project)
  def touch_project_last_accessed(project)
    return unless user_signed_in?

    permission = current_user.project_permissions.find_by(project_id: project.id)
    return unless permission
    return if permission.last_accessed_at&.> 1.hour.ago

    permission.update_column(:last_accessed_at, Time.current)
  end

  # Fetches all objects for the current project
  # (override for more complex logic)
  def project_objects
    # Use policy_scope to ensure that Pundit tracks
    policy_scope(@project.send(object_type.downcase.pluralize))
  end

  # Sets the objects for the view
  def set_objects
    @objects = find_objects
    instance_variable_set("@#{object_type.downcase.pluralize}", @objects)
  end

  # Searches and filters the objects
  # (can be overridden for more complex logic)
  def find_objects
    base_query = @base_query || project_objects

    # Eager loading for common associations based on the object type
    base_query = add_eager_loading(base_query)

    # If a search term is present, apply the search
    base_query = apply_search(base_query) if params[:search].present?

    # Sort the results
    apply_sorting(base_query)
  end

  # Adds eager loading for common associations
  def add_eager_loading(query)
    case object_type
    when 'Note'
      query.includes(:tags, :taggings)
    when 'Document'
      query.includes(:current_version, :document_versions)
    when 'Ticket'
      includes = []
      includes << :ticket_status if query.klass.reflect_on_association(:ticket_status)
      includes << :ticket_priority if query.klass.reflect_on_association(:ticket_priority)
      includes << :assigned_to_user if query.klass.reflect_on_association(:assigned_to_user)
      includes << :tags if query.klass.reflect_on_association(:tags)

      includes.any? ? query.includes(includes) : query
    else
      query
    end
  end

  # Sets a single object based on ID (for show, edit, update, destroy)
  def set_object
    @object = project_objects.find(params[:id])
    instance_variable_set("@#{object_type.downcase}", @object)
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error "#{object_type} with ID #{params[:id]} not found in project #{@project.id}"
    handle_not_found
  end

  # Determines whether an object is selected (e.g. via URL parameter)
  def set_selected_object
    object_param = "#{object_type.downcase}_id"
    if params[object_param].present?
      begin
        @selected_object = project_objects.find(params[object_param])
        instance_variable_set("@selected_#{object_type.downcase}", @selected_object)
      rescue ActiveRecord::RecordNotFound
        @selected_object = nil
      end
    else
      @selected_object = nil
    end
  end

  # Authorizes project access
  def authorize_project_access
    # Convert singular to plural for the area_access method
    area = object_type.underscore.pluralize.to_sym
    authorize_area_access(area, action_permission_level)
  end

  # Sets the SmartFolders for the current object type
  def set_smart_folders
    smart_folders = policy_scope(SmartFolder)
                    .where(organisation_id: current_organisation.id)
                    .where(target_object_type: [object_type, 'All'])
                    .order(name: :asc)

    smart_folders = smart_folders.where('project_id IS NULL OR project_id = ?', @project.id) if @project.present?

    instance_variable_set("@#{object_type.downcase}_smart_folders", smart_folders)
  end

  # Applies the SmartFolder activated via params[:smart_folder_id] to the
  # base query and sets @active_smart_folder. Folders with a foreign
  # object type are ignored; for an unknown ID the query stays
  # unchanged (missing_folder_flash controls whether a message appears).
  def apply_smart_folder_filter(base_query, missing_folder_flash: false)
    return base_query if params[:smart_folder_id].blank?

    @active_smart_folder = policy_scope(SmartFolder).find(params[:smart_folder_id])
    return base_query unless [object_type, 'All'].include?(@active_smart_folder.target_object_type)
    # The reader edited a dissolvable view: apply_ad_hoc_filters applies the
    # effective conditions instead (AdHocFilterable, S3a).
    return base_query if edited_saved_view?

    # SmartFolderService returns the folder results; filter to objects of
    # the current project
    folder_items = SmartFolderService.new(@active_smart_folder, current_user).fetch_results[:items]

    if folder_items.is_a?(ActiveRecord::Relation) && folder_items.klass.name == object_type
      folder_items.where(project_id: @project.id)
    elsif folder_items.is_a?(Array)
      object_ids = folder_items
                   .select { |item| item.is_a?(object_type.constantize) && item.project_id == @project.id }
                   .map(&:id)
      object_type.constantize.where(id: object_ids, project_id: @project.id)
    else
      base_query
    end
  rescue ActiveRecord::RecordNotFound
    flash.now[:alert] = t('smart_folders.not_found', default: 'Der angegebene Ticket Filter wurde nicht gefunden.') if missing_folder_flash
    base_query
  end

  # The filtered list for the current address, before pagination: the active
  # folder, then the list filters (ad hoc, search, sorting). ONE owner
  # (doc/ticket_bulk_edit_plan.md, S0): index paginates it, and a bulk action
  # resolves "alle Treffer" from the same method, so the set a reader saw and
  # the set a run touches can never be computed two different ways.
  def filtered_objects
    apply_list_filters(apply_smart_folder_filter(@base_query || project_objects, missing_folder_flash: true))
  end

  # Shared filter pipeline for the lists: ad-hoc filter → search → sorting
  def apply_list_filters(base_query)
    apply_sorting(apply_search(apply_ad_hoc_filters(base_query)))
  end

  # Strict cache-control headers to avoid cache problems
  def set_strict_no_cache_headers
    response.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
    response.headers['Pragma'] = 'no-cache'
    response.headers['Expires'] = 'Fri, 01 Jan 1990 00:00:00 GMT'
  end

  # HTML/fallback rendering of the index action: Turbo-Frame requests get
  # only the list partial in the frame, otherwise the with_object or list_only template
  def render_index_html
    if turbo_frame_request? && turbo_frame_request_id == results_frame_id
      render html: helpers.turbo_frame_tag(results_frame_id) {
        helpers.render(partial: results_partial_path, locals: build_results_locals)
      }, layout: false
    elsif @selected_object.present?
      render with_object_template || :with_object
    else
      render list_only_template || :list_only
    end
  end

  # Builds the locals for the results template
  def build_results_locals
    locals = {
      object_type.downcase.pluralize.to_sym => @objects,
      :pagy => @pagy,
      :sortable_header => true,
      :items => params[:items]
    }

    # Always pass the search parameter explicitly
    locals[:search] = params[:search]

    # Add SmartFolder context
    if params[:smart_folder_id].present?
      locals[:smart_folder_id] = params[:smart_folder_id]
      locals[:active_smart_folder] = @active_smart_folder
    end

    # Add filter metadata when a filter is active
    locals[:ad_hoc_filter_metadata] = ad_hoc_filter_metadata if ad_hoc_filter_active?

    # Add the selected note if present
    locals["selected_#{object_type.downcase}".to_sym] = @selected_object if @selected_object.present?

    locals
  end

  # Handles objects that were not found
  def handle_not_found
    respond_to do |format|
      format.html do
        flash[:alert] = t("#{object_type.downcase.pluralize}.not_found", default: "Das angeforderte #{object_type} wurde nicht gefunden.")
        redirect_to send("organisation_project_#{object_type.downcase.pluralize}_path", @current_organisation, @project)
      end
      format.turbo_stream do
        flash[:alert] = t("#{object_type.downcase.pluralize}.not_found", default: "Das angeforderte #{object_type} wurde nicht gefunden.")
        redirect_to send("organisation_project_#{object_type.downcase.pluralize}_path", @current_organisation, @project)
      end
      format.json { render json: { error: t('flash.shared.object_not_found', object: object_type) }, status: :not_found }
    end
  end

  # Calculates the correct page for the selected object and redirects
  def calculate_and_redirect_to_object_page
    # Base query incl. active SmartFolder filter (silent for an unknown folder)
    base_query = apply_smart_folder_filter(@base_query || project_objects)
    sorted_query = apply_list_filters(base_query)

    # Find the position of the selected object in the sorted list
    object_position = nil
    # Use pluck(:id) instead of select(:id) to fetch only the IDs without loading
    # model instances. .uniq is load-bearing: pluck on a relation with includes
    # forces the eager-load JOINs, and the fan-out (tags, assignees) duplicated
    # every id - the selected ticket's first occurrence then sat at position 41+
    # of a 20-ticket list, and the redirect sent the reader to an empty page 3
    # (found live, 03.09.2026). The show route's own calculation carries the
    # same rule as a hand-built join-free query.
    sorted_ids = sorted_query.pluck(:id).uniq
    sorted_ids.each_with_index do |obj_id, index|
      if obj_id == @selected_object.id
        object_position = index + 1
        break
      end
    end

    # If the object was not found, continue normally
    return unless object_position

    # Calculate the correct page
    items_per_page_value = items_per_page
    correct_page = ((object_position - 1) / items_per_page_value) + 1

    # If we are already on the correct page, continue
    return if correct_page == 1

    # Otherwise redirect to the correct page. sort is a NESTED hash
    # (sort[column]/sort[direction]) - permit(:sort) silently dropped it, so
    # the redirect landed on the page number computed under the CURRENT sort
    # but rendered under the DEFAULT sort.
    redirect_params = params.permit(:search, :search_mode, :items, "#{object_type.downcase}_id".to_sym, :smart_folder_id, sort: %i[column direction])
    redirect_params[:page] = correct_page
    # The three filter params travel together: filter[] alone would turn an
    # edited view (AdHocFilterable) back into the saved one on the landing page.
    redirect_params[:filter] = params[:filter].to_unsafe_h if params[:filter].present?
    redirect_params[:filter_op] = params[:filter_op].to_unsafe_h if params[:filter_op].present?
    redirect_params[:filter_drop] = Array(params[:filter_drop]) if params[:filter_drop].present?

    redirect_to url_for(redirect_params) and return
  end

  # Returns the object type (override in concrete controllers)
  def object_type
    raise NotImplementedError, 'Subclasses must implement object_type'
  end

  # Returns the required permission level for the current action
  def action_permission_level
    case action_name
    when 'index', 'show'
      :read
    else
      :write
    end
  end

  # ID of the detail frame
  def detail_frame_id
    "#{object_type.downcase}_display_frame"
  end

  # ID of the results frame
  def results_frame_id
    case object_type.downcase
    when 'ticket'
      'tickets_list_frame'
    when 'note'
      'notes_results'
    else
      "#{object_type.downcase.pluralize}_results"
    end
  end

  # Path to the results template
  def results_partial_path
    "organisations/#{object_type.downcase.pluralize}/#{object_type.downcase.pluralize}_results"
  end

  # Path to the object-specific show partial
  def object_show_partial
    "organisations/#{object_type.downcase.pluralize}/#{object_type.downcase}_show"
  end

  # Template for the view with a selected object
  def with_object_template
    nil
  end

  # Template for the plain list view
  def list_only_template
    nil
  end

  # Authorizes access to the project area
  def authorize_area_access(area, level)
    return if policy(@project).area_access?(area, level)

    flash[:alert] = t("unauthorized.#{level}", scope: "projects.#{area}", default: 'Sie haben keine ausreichenden Berechtigungen für diese Aktion.')
    redirect_to organisation_project_path(@current_organisation, @project)
  end
end
