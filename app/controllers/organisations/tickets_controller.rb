# frozen_string_literal: true

# Read path map for this whole area: docs/architektur/tickets_lesepfad.md
#
# Two things are not visible from this file and bite regularly:
#   1. ObjectListController contributes five before_actions and its own index/show defaults.
#      This controller OVERRIDES index, show, find_objects and project_objects — always read
#      both versions (see app/controllers/concerns/CLAUDE.md).
#   2. Status and priority are strings inside the custom_attributes JSONB, configured per
#      project via TicketAttributeDefinition. There is no ticket_statuses table any more.
class Organisations::TicketsController < Organisations::BaseController
  include ObjectListController
  include TicketListColumns
  include ActionView::RecordIdentifier
  include PerformanceOptimized
  include ViewportSwitchable

  # Exclude set_object from ObjectListController for all actions, since we use set_ticket
  skip_before_action :set_object

  # Setup for sorting, paging and search
  setup_sortable Ticket
  add_sortable_columns :id, :title, :number, :created_at, :updated_at
  # status/priority live in JSONB custom_attributes (the former ticket_statuses /
  # ticket_priorities tables were dropped). Header links use the 'custom_'-prefixed
  # column key; both forms are whitelisted and apply_sorting routes them through a
  # configured-order sort (see below).
  add_sortable_columns(*Ticket.sortable_custom_attribute_keys)
  setup_searchable Ticket, [:title]

  before_action :set_ticket, only: %i[show edit update destroy create_summary move_preflight move update_kanban_attribute timeline]
  before_action :set_tickets, only: %i[create update]
  before_action :set_view_configuration, only: %i[index show]
  before_action :load_ticket_notification_counts, only: %i[index show]
  prepend_before_action :set_viewport_mode
  before_action :authorize_ticket_write,
                only: %i[new create update bulk_edit bulk_summary bulk_update undo_bulk_run bulk_impact bulk_move bulk_destroy]
  before_action :authorize_ticket_deletion, only: [:destroy]
  # The lane's fast path (doc/kanban_ticket_als_bahn_plan.md, section 4.2): a
  # request for turbo-frame ticket_display_frame renders the lane alone, so the
  # list's own callbacks step aside. set_objects would run TicketSearchQuery
  # before the action starts (object_list_controller.rb), for a page that is
  # not rendered. Project, ticket, authorisation and the view configuration
  # stay.
  skip_before_action :set_objects, :set_smart_folders, if: :ticket_lane_frame_request?

  # Define the object type for the ObjectListController concern
  def object_type
    'Ticket'
  end

  # Template for the view with a selected object
  def with_object_template
    :index
  end

  # Template for the pure list view
  def list_only_template
    :index
  end

  # Override the detail frame ID
  def detail_frame_id
    'ticket_display_frame'
  end

  # Override project_objects for extended eager loading
  def project_objects
    base_query = @project.tickets
                         .includes(optimized_ticket_includes)

    # Use policy_scope to ensure that Pundit tracks
    policy_scope(base_query)
  end

  # GET /projects/:project_id/tickets/:id
  #
  # Shows a task with all associated content
  # Combines posts and time sessions in a chronological timeline
  #
  # Permissions:
  # - User must be a member of the project
  # - User must have read permission for the ticket area
  def show
    # Explicit authorization for Pundit
    authorize @ticket

    # Prevent caching of ticket views
    response.headers['Cache-Control'] = 'no-cache, no-store, must-revalidate'
    response.headers['Pragma'] = 'no-cache'
    response.headers['Expires'] = '0'

    @post = Post.new(ticket: @ticket, user: current_user)

    respond_to do |format|
      format.html do
        # Check if this is a Turbo Frame request for the ticket-header-content frame
        if turbo_frame_request? && request.headers['Turbo-Frame'] == 'ticket-header-content'
          render partial: 'organisations/tickets/ticket_header_show',
                 locals: { frame_id: 'ticket-header-content', ticket: @ticket },
                 layout: false
          return
        end

        # The lane alone, what a row or card click fetches (layout: false,
        # Turbo keeps only that frame anyway). Rendering the whole page for it
        # ran the filter pipeline and the page calculation for nothing.
        if ticket_lane_frame_request?
          @selected_ticket = @ticket
          render partial: 'organisations/tickets/ticket_lane', layout: false
          return
        end

        # For direct HTML requests, render the index view with the selected ticket
        @selected_ticket = @ticket
        @open_content = true

        # Load tickets for the list
        base_query = @project.tickets
                             .includes(optimized_ticket_includes)
        Rails.logger.debug "[TICKETS#SHOW] Base query count: #{base_query.count}"

        base_query = apply_ad_hoc_filters(base_query)
        search_query = apply_search(base_query)
        Rails.logger.debug "[TICKETS#SHOW] After search count: #{search_query.count}"

        sorted_query = apply_sorting(search_query)
        Rails.logger.debug "[TICKETS#SHOW] After sorting count: #{sorted_query.count}"

        # Calculate the correct page for the selected ticket if no page param is given
        if params[:page].blank?
          # Find position of selected ticket in sorted list
          # Create a simple query without JOINs for position calculation
          simple_query = @project.tickets
          simple_query = apply_ad_hoc_filters(simple_query)
          simple_query = apply_search(simple_query)
          simple_query = apply_sorting(simple_query)

          ticket_ids = simple_query.pluck(:id)
          ticket_position = ticket_ids.index(@ticket.id)

          Rails.logger.debug "[TICKETS#SHOW] Total ticket IDs: #{ticket_ids.count}"
          Rails.logger.debug "[TICKETS#SHOW] Looking for ticket: #{@ticket.id}"

          if ticket_position
            items_per_page_value = items_per_page
            correct_page = (ticket_position / items_per_page_value) + 1
            params[:page] = correct_page
            Rails.logger.info "[TICKETS#SHOW] Auto-calculated page #{correct_page} for ticket at position #{ticket_position + 1}"
          else
            Rails.logger.info '[TICKETS#SHOW] Ticket not found in sorted list, using page 1'
            params[:page] = 1
          end
        end

        @pagy, @tickets = paginate(sorted_query)

        # Set sort_params for pagination
        @sort_params = sort_params

        # Load Smart Folders
        @ticket_smart_folders = policy_scope(SmartFolder)
                                .where(organisation_id: @current_organisation.id)
                                .where('target_object_type = ? OR target_object_type = ?', 'Ticket', 'All')
                                .where(project_id: @project.id)
                                .order(:name)

        # A full page in kanban mode shows the board with the lane open: ONE
        # builder, fed by the same pipeline as index, so both roads show the
        # same cards (doc/kanban_ticket_als_bahn_plan.md, section 4.2).
        build_kanban_board(apply_list_filters(@base_query || project_objects), selected: @ticket) if @view_mode == 'kanban'

        render :index
      end

      format.turbo_stream do
        # Full ticket display (header + timeline) for layout content and Kanban slide-over
        render turbo_stream: turbo_stream.update(
          'ticket_display_frame',
          partial: 'organisations/tickets/ticket_display',
          locals: {
            ticket: @ticket,
            post: @post,
            project: @project,
            current_organisation: @current_organisation
          }
        )
      end
    end
  end

  # GET /projects/:project_id/tickets/:id/timeline
  # Lazy-loaded timeline (posts + activities + time sessions) for the ticket show page.
  def timeline
    authorize @ticket, :show?
    @timeline_items = TicketTimelineService.new(@ticket, current_user).timeline_items
    render layout: false
  end

  # Override build_results_locals to add ticket-specific locals
  def build_results_locals
    locals = super

    # Extend with ticket-specific locals
    locals[:current_search_mode] = @current_search_mode
    locals[:items_per_page] = items_per_page
    locals[:current_organisation] = @current_organisation
    locals[:project] = @project
    locals[:selected_ticket] = @selected_ticket || @selected_object
    locals[:columns] = @columns if @columns.present?
    locals
  end

  # Override set_smart_folders to load ticket-specific smart folders
  def set_smart_folders
    @ticket_smart_folders = policy_scope(SmartFolder)
                            .where(organisation_id: current_organisation.id)
                            .where(target_object_type: %w[Ticket All])
                            .where('project_id IS NULL OR project_id = ?', @project.id)
                            .order(name: :asc)
  end

  # Override the index action — Kanban bypasses ObjectListController (no pagination)
  def index
    if @view_mode == 'kanban'
      authorize Ticket
      response.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
      response.headers['Pragma'] = 'no-cache'

      # Same filter pipeline as the table list (ad-hoc filter → search → sorting,
      # see ObjectListController#apply_list_filters). @base_query is already populated
      # by find_objects (incl. the smart-folder filter when TicketSearchQuery ran), so
      # we feed it through the shared pipeline instead of re-listing the steps here.
      build_kanban_board(apply_list_filters(@base_query || project_objects), selected: @selected_ticket)

      # Filter-bar navigation (search, ad-hoc filters, search depth) reloads the
      # tickets_list_frame turbo-frame. In board mode that frame wraps the board
      # (see _kanban_list_frame). Answer the frame request with just the board so a
      # search keystroke doesn't re-render the whole page (filter bar, modal, …).
      # results_frame_id is the single source of truth for the frame name (= the id
      # the filter bar targets via frame_id:), so the check can never drift from it.
      if turbo_frame_request? && turbo_frame_request_id == results_frame_id
        render partial: 'organisations/tickets/kanban_list_frame', layout: false
      else
        render :index
      end
    else
      super
    end
  end

  # Override find_objects to integrate special ticket logic
  def find_objects
    # Handle session-based selection
    handle_ticket_selection

    # Load available smart folders for tickets
    set_smart_folders

    # Make search mode available to the view (URL parameter as single source of truth)
    @current_search_mode = params[:search_mode].presence || 'content'

    # When a smart folder was activated OR a search with search_mode is performed
    condition = params[:smart_folder_id].present? || (params[:search].present? && @current_search_mode != 'title_only')

    if condition
      begin
        query_options = {
          current_user: current_user,
          policy_scope: policy_scope(SmartFolder)
        }

        # SmartFolder default sort: if no explicit user sort, use the smart folder sorting
        if params[:smart_folder_id].present? && params[:sort].blank?
          sf = query_options[:policy_scope].find_by(id: params[:smart_folder_id])
          params[:sort] = ActionController::Parameters.new('column' => sf.effective_sort_column, 'direction' => sf.effective_sort_direction) if sf
        end

        # An edited dissolvable view is applied as effective ad-hoc filters by
        # apply_list_filters (AdHocFilterable, S3a); the folder query steps aside.
        query_params = edited_saved_view? ? params.except(:smart_folder_id) : params
        query = TicketSearchQuery.new(@project, query_params, query_options)
        result = query.call

        # Set @base_query for ObjectListController
        @base_query = result

        return result
      rescue TicketSearchQuery::SmartFolderNotFoundError => e
        flash.now[:alert] = e.message
        return project_objects
      rescue StandardError => e
        Rails.logger.error "[TICKETS#FIND_OBJECTS] TicketSearchQuery Error: #{e.class} - #{e.message}"
        return project_objects
      end
    end

    # Default behavior of ObjectListController (only for title_only without smart folder)
    super
  end

  # Custom-attribute sort: select fields (status/priority) by configured option order,
  # date fields (due_date) chronologically. Dispatch lives in Ticket.custom_attribute_sort_sql
  # (shared with the query path). Every other column uses the generic Sortable path.
  def apply_sorting(query)
    attr_name = Ticket.sortable_custom_attribute(sort_column)
    return super unless attr_name

    query.reorder(Arel.sql(Ticket.custom_attribute_sort_sql(attr_name, @project, sort_direction)))
  end

  # Override apply_search to disable the default search when TicketSearchQuery was used
  def apply_search(base_query)
    # If we already used TicketSearchQuery, do not apply another search
    return base_query if params[:smart_folder_id].present? || (params[:search].present? && @current_search_mode != 'title_only')

    # Otherwise use the default behavior
    super
  end

  # Override set_selected_object - URL-based
  def set_selected_object
    ticket_id = params[:ticket_id]

    if ticket_id.present?
      begin
        @selected_object = @project.tickets.find(ticket_id)
        @selected_ticket = @selected_object
        @open_content = true
      rescue ActiveRecord::RecordNotFound
        @selected_object = nil
        @selected_ticket = nil
      end
    else
      @selected_object = nil
      @selected_ticket = nil
      @open_content = false
    end
  end

  # Handle ticket selection based on URL parameters
  def handle_ticket_selection
    ticket_id = params[:ticket_id]

    if ticket_id.present?
      begin
        @selected_object = @project.tickets.find(ticket_id)
        @selected_ticket = @selected_object

        # Load detail view data (timeline is lazy-loaded via turbo-frame)
        @post = Post.new(ticket: @selected_object, user: current_user)
        @open_content = true
      rescue ActiveRecord::RecordNotFound
        @selected_object = nil
        @selected_ticket = nil
        @open_content = false
      end
    else
      @open_content = false
    end
  end

  # Override action_permission_level for ticket-specific permissions
  def action_permission_level
    case action_name
    when 'index', 'show'
      :read
    else
      :write
    end
  end

  # GET /projects/:project_id/tickets/bulk_edit
  #
  # The bulk panel's shell for the lane (doc/ticket_bulk_edit_plan.md, slice 3).
  # The selection controller loads it into turbo-frame#ticket_display_frame on
  # the first tick; the ticket detail and this panel take turns in that frame.
  # The shell carries no selection of its own: the numbers come from the
  # selection controller over a window event once the panel is connected, so a
  # tick never re-renders the frame and nothing in the lane moves. A plain
  # request (a bookmark, a stale link) lands on the list. Authorisation is the
  # before_action :authorize_ticket_write, the gate every write action shares.
  def bulk_edit
    authorize @project, :bulk_edit_tickets?
    return redirect_to organisation_project_tickets_path(@current_organisation, @project) unless turbo_frame_request?

    # The other actions (slice 7): the move dialog lists the projects the
    # reader may see, the rights decide when the dialog is offered at all.
    @bulk_target_projects = policy_scope(Project).active.where.not(id: @project.id).order(:name)
    @bulk_can_move = policy(@project).bulk_move_tickets?
    @bulk_can_delete = policy(@project).bulk_delete_tickets?
    render :bulk_edit, layout: false
  end

  # POST /projects/:project_id/tickets/bulk_summary.json
  #
  # What the selected tickets hold today, per field the panel can change
  # (doc/ticket_bulk_edit_plan.md, slice 4). The selection arrives as the
  # panel names it (selection[mode], selection[ids][], selection[expected_count])
  # in the JSON body, together with the list's address in the query, which is
  # how mode "all" is resolved from the same filtered_objects the table
  # paginates. A POST although it reads: a selection of a full page (200 ids)
  # does not fit into a request line. A selection the resolver refuses
  # answers with its code and no numbers.
  def bulk_summary
    authorize @project, :bulk_edit_tickets?
    resolution = resolve_bulk_selection
    return render json: { error: resolution.error }, status: :unprocessable_content unless resolution.ok?

    # The people's labels follow the reader's name display, as in the panel's own list.
    fields = Tickets::BulkFields.for(project: @project, user: current_user, name_mode: helpers.viewer_name_display_mode)
    render json: Tickets::BulkSummary.call(project: @project, ticket_ids: resolution.ids, fields: fields)
  end

  # PATCH /projects/:project_id/tickets/bulk_update
  #
  # The run (doc/ticket_bulk_edit_plan.md, slice 6): the selection as the
  # panel names it, the list's address for mode "all", the changes the panel
  # collected, and the stock digests the reader decided on. One actor for one
  # ticket and for many (D13). The answer re-renders the list for the current
  # address (what matches NOW) and writes the result line into the selection
  # row's slot; a refused run writes only its reason, status 422, and nothing
  # was written.
  def bulk_update
    authorize @project, :bulk_edit_tickets?
    resolution = resolve_bulk_selection
    return render_bulk_refusal(resolution.error) unless resolution.ok?

    result = Actors::ApplyTicketChanges.call(
      project: @project, ticket_ids: resolution.ids, changes: bulk_changes_params,
      current_user: current_user, expected_stock: bulk_stock_params,
      name_mode: helpers.viewer_name_display_mode
    )
    return render_bulk_refusal(result.code, result.errors) unless result.success?

    render_bulk_run(result.resource)
  end

  # PATCH /projects/:project_id/tickets/bulk_runs/:id/undo
  def undo_bulk_run
    authorize @project, :bulk_edit_tickets?
    run = @project.ticket_bulk_runs.find(params[:id])
    result = Actors::UndoTicketBulkRun.call(run: run, current_user: current_user)
    return render_bulk_refusal(result.code, result.errors) unless result.success?

    render_bulk_run(result.resource)
  end

  # POST /projects/:project_id/tickets/bulk_impact.json
  #
  # What a move or a delete of the selection takes with it, for the dialog's
  # sentence (doc/ticket_bulk_edit_plan.md, D15, slice 7): comments,
  # attachments, time sessions, sub-tickets; with a target project also the
  # assignments and subscriptions the target cannot keep. Read with the write
  # right, because the dialog belongs to the panel.
  def bulk_impact
    authorize @project, :bulk_edit_tickets?
    resolution = resolve_bulk_selection
    return render json: { error: resolution.error }, status: :unprocessable_content unless resolution.ok?

    target = bulk_target_project
    render json: Tickets::BulkImpact.call(project: @project, ticket_ids: resolution.ids, target_project: target)
  end

  # POST /projects/:project_id/tickets/bulk_move
  #
  # The bulk move (slice 7): the selection and the target project as JSON,
  # the list's address in the query. The right is the one the single move
  # asks (move_tickets), plus write access to the target. The answer is the
  # run's result line and the re-rendered list; the moved tickets have left
  # it, so the selection is cleared by the panel.
  def bulk_move
    authorize @project, :bulk_move_tickets?
    resolution = resolve_bulk_selection
    return render_bulk_refusal(resolution.error) unless resolution.ok?

    target = bulk_target_project
    return render_bulk_refusal(:target_project) unless target
    return render_bulk_refusal(:target_no_access) unless policy(target).area_access?(:tickets, :write)

    result = Actors::MoveTickets.call(project: @project, ticket_ids: resolution.ids, target_project: target,
                                      current_user: current_user)
    return render_bulk_refusal(result.code, result.errors) unless result.success?

    render_bulk_run(result.resource)
  end

  # DELETE /projects/:project_id/tickets/bulk_destroy
  #
  # The bulk delete (D15, slice 7): only after the dialog named what goes with
  # the tickets; the right is the one the single delete asks (delete_tickets).
  def bulk_destroy
    authorize @project, :bulk_delete_tickets?
    resolution = resolve_bulk_selection
    return render_bulk_refusal(resolution.error) unless resolution.ok?

    result = Actors::DestroyTickets.call(project: @project, ticket_ids: resolution.ids, current_user: current_user)
    return render_bulk_refusal(result.code, result.errors) unless result.success?

    render_bulk_run(result.resource)
  end

  # GET /projects/:project_id/tickets/new
  #
  # Renders the writing surface (the one ticket form) into turbo-frame#writing_surface; the "+" buttons on
  # the ticket list and the dashboard target that frame. A plain request (stale link, bookmark)
  # lands on the ticket list. Authorisation is the before_action :authorize_ticket_write.
  def new
    skip_authorization
    return redirect_to organisation_project_tickets_path(@current_organisation, @project) unless turbo_frame_request?

    @ticket = @project.tickets.build
    apply_kanban_preset(@ticket)
    render partial: 'organisations/tickets/writing_surface',
           locals: { ticket: @ticket, project: @project, source: writing_surface_source },
           layout: false
  end

  # POST /projects/:project_id/tickets
  #
  # Creates a new task
  # Uses the SaveTicket actor for the business logic
  #
  # Permissions:
  # - User must be a member of the project
  # - User must have write permission for the ticket area
  def create
    # Authorization is already checked by before_action :authorize_ticket_write

    actor = Actors::SaveTicket.new(project: @project, params: ticket_params, current_user: current_user)
    result = actor.call
    @ticket = result.resource

    # Authorize the created ticket for Pundit
    authorize @ticket

    if result.success?
      @post = Post.new

      respond_to do |format|
        format.turbo_stream do
          if writing_surface_source.in?(%w[dashboard mobile_detail])
            # Dashboard and standalone mobile detail have no list frame to reload.
            # Close the surface and navigate to the new ticket.
            render turbo_stream: [
              turbo_stream.update('writing_surface', ''),
              turbo_stream.append_all(
                'body',
                partial: 'organisations/tickets/create_redirect_dashboard',
                locals: { redirect_url: writing_surface_source == 'mobile_detail' ? organisation_project_ticket_path(@current_organisation, @project, @ticket, viewport: 'mobile') : organisation_project_tickets_path(@current_organisation, @project, ticket_id: @ticket.id) }
              )
            ]
          elsif writing_surface_source == 'kanban' || @viewport_mode == 'mobile'
            # From a board column ("+ Ticket"): close the surface and have the
            # board reload its frame from the page's live address (a custom
            # stream action, application.js). The form posts only `source` and
            # the ticket's fields; a board built here ran on the unfiltered
            # project scope and forgot the page's filters, its search, its saved
            # view and its open ticket. The frame request through index carries
            # all of them, and the open ticket's card with it
            # (doc/kanban_ticket_als_bahn_plan.md, section 4.2).
            render turbo_stream: [
              turbo_stream.update('writing_surface', ''),
              turbo_stream.action(:reloadFrame, 'tickets_list_frame')
            ]
          else
            # From the index page: normal processing with frame updates
            streams = []

            # Show the selected ticket - with header AND content
            streams << turbo_stream.update(
              'ticket_display_frame',
              partial: 'organisations/tickets/ticket_display',
              locals: {
                ticket: @ticket,
                post: @post,
                project: @project,
                current_organisation: @current_organisation
              }
            )

            # Update the ticket list
            @selected_ticket = @ticket
            @tickets = set_tickets
            @pagy, @tickets = paginate(@tickets)

            streams << turbo_stream.update(
              'tickets_list_frame',
              partial: 'organisations/tickets/tickets_results',
              locals: {
                tickets: @tickets,
                pagy: @pagy,
                sortable_header: true,
                selected_ticket: @selected_ticket,
                sort_params: @sort_params || {},
                smart_folder_id: params[:smart_folder_id],
                current_organisation: @current_organisation,
                project: @project,
                columns: ticket_list_columns(@project)
              }
            )

            # Close the writing surface (it lives in turbo-frame#writing_surface), show the content
            # column and highlight the new row.
            streams << turbo_stream.update('writing_surface', '')
            streams << turbo_stream.append_all(
              'body',
              partial: 'organisations/tickets/create_show_index',
              locals: { ticket_id: @ticket.id }
            )

            render turbo_stream: streams
          end
        end

        format.html { redirect_to organisation_project_tickets_path(@current_organisation, @project, ticket_id: @ticket.id), notice: t('flash.tickets.created') }
      end
    else
      # Authorize the ticket even on failure for Pundit
      authorize @ticket

      respond_to do |format|
        format.turbo_stream do
          # Errors stay inside the writing surface; the frame is replaced as a whole.
          render turbo_stream: turbo_stream.replace(
            'writing_surface',
            partial: 'organisations/tickets/writing_surface',
            locals: { ticket: @ticket, project: @project, source: writing_surface_source }
          )
        end
        # The surface create is a Turbo Stream request (handled above). The HTML branch only fires
        # for a non-Turbo POST; the full-page form that used to drive it is gone, so we cannot
        # `render :new` anymore. Fall back to the index with the validation errors as a flash.
        format.html do
          redirect_to organisation_project_tickets_path(@current_organisation, @project),
                      alert: @ticket.errors.full_messages.to_sentence
        end
      end
    end
  end

  # POST /projects/:project_id/tickets/:id/create_summary
  #
  # Creates an AI-generated summary for the task.
  # The OpenAI logic lives in TicketSummaryService — here only authorization
  # and translation of the service result into flash + response format.
  #
  # Permissions:
  # - User must be a member of the project
  # - User must have write permission for the ticket area
  def create_summary
    # Write-permission gate runs in ObjectListController#authorize_project_access (before_action)
    # Explicit authorization for Pundit
    authorize @ticket, :update?

    result = TicketSummaryService.new(
      ticket: @ticket,
      organisation: current_organisation,
      updater: current_user
    ).call

    case result.status
    when :success
      render_summary_success
    when :save_failed
      render_summary_save_failed
    when :ai_disabled
      render_summary_failure(t('shared.ai.disabled_member_hint'))
    when :quota_exceeded
      render_summary_failure(t('shared.ai.quota_exhausted_member_hint'))
    when :no_api_key
      render_summary_failure(t('flash.tickets.ai_no_api_key'))
    when :invalid_key
      render_summary_failure(t('flash.tickets.ai_invalid_key'))
    when :not_configured
      flash[:alert] = t('flash.tickets.ai_not_configured')
      redirect_back(fallback_location: organisation_project_tickets_path(current_organisation, @project))
    else
      render_summary_failure(t('flash.tickets.ai_error'))
    end
  end

  # GET /projects/:project_id/tickets/:id/edit
  #
  # Shows a form to edit a task
  #
  # Permissions:
  # - User must be a member of the project
  # - User must have write permission for the ticket area
  # GET /projects/:project_id/tickets/:id/edit
  #
  # Same writing surface as #new, with the ticket's data, into turbo-frame#writing_surface (the edit
  # buttons target that frame). A plain request lands on the list with the ticket open.
  def edit
    authorize @ticket, :update?
    return redirect_to organisation_project_tickets_path(@current_organisation, @project, ticket_id: @ticket.id) unless turbo_frame_request?

    render partial: 'organisations/tickets/writing_surface',
           locals: { ticket: @ticket, project: @project, source: writing_surface_source },
           layout: false
  end

  # PATCH/PUT /projects/:project_id/tickets/:id
  #
  # Updates an existing task
  # Uses the SaveTicket actor for the business logic
  #
  # Permissions:
  # - User must be a member of the project
  # - User must have write permission for the ticket area
  def update
    authorize @ticket, :update?

    actor = Actors::SaveTicket.new(project: @project, params: ticket_params, id: params[:id], current_user: current_user)
    result = actor.call
    @ticket = result.resource

    if result.success?
      respond_to do |format|
        format.turbo_stream do
          # Set instance variables needed for the view (timeline lazy-loads via turbo-frame)
          @post = Post.new(ticket: @ticket, user: current_user)
          @tickets = set_tickets if defined?(set_tickets)
          @columns = ticket_list_columns(@project)

          render :update
        end
        format.html { redirect_to organisation_project_tickets_path(@current_organisation, @project, ticket_id: @ticket.id), notice: t('flash.tickets.updated') }
      end
    else
      respond_to do |format|
        format.turbo_stream { render :update }
        format.html do
          redirect_to organisation_project_tickets_path(@current_organisation, @project, ticket_id: @ticket.id),
                      alert: @ticket.errors.full_messages.to_sentence
        end
      end
    end
  end

  # DELETE /projects/:project_id/tickets/:id
  #
  # Deletes a task and all associated content
  #
  # Permissions:
  # - User must be a member of the project
  # - User must have write permission for the ticket area
  # - User must have the 'delete_tickets' permission or be an admin
  def destroy
    # The friendly redirect for users without the permission lives in the
    # before_action :authorize_ticket_deletion (policy().destroy? + flash). That
    # check does NOT mark the request as authorised for Pundit, so without this
    # call verify_authorized raised AFTER the record was gone: the browser got a
    # 500 for a frame-targeted submission and left the edit form standing.
    # Same shape as #update (authorize_ticket_write + authorize @ticket, :update?).
    authorize @ticket, :destroy?

    ticket_id = @ticket.id # Save the ID before deletion
    deletion_success = @ticket.destroy

    respond_to do |format|
      if deletion_success
        format.turbo_stream do
          streams = []

          # Drop the row from the list (desktop and mobile frame alike) instead of
          # re-rendering the whole list: the DELETE carries no search/sort/smart-folder
          # params, a re-render would reset the user's view. Same selector the update
          # stream uses (update.turbo_stream.erb). The former target 'tickets_results'
          # matched no element, so the deleted ticket kept sitting in the list.
          streams << turbo_stream.remove_all("tr[data-ticket-id='#{ticket_id}'], .mobile-ticket-row[data-ticket-id='#{ticket_id}']")
          # A deleted sub-ticket leaves its parent one short (TicketListColumns).
          streams.concat(ticket_list_parent_streams(@ticket))

          # Clear the content frame (desktop + mobile) with a message
          streams << turbo_stream.update_all(
            '#ticket_display_frame',
            partial: 'shared/empty_content',
            locals: {
              message: t('flash.tickets.deleted_empty_content_title'),
              description: t('flash.tickets.deleted_empty_content_description')
            }
          )

          # Success notice through the standard flash (NeoFlashComponent: fixed position,
          # auto-hide). The former hand-built notice in destroy_close sat unpositioned top-left.
          streams << turbo_stream.update('flash', partial: 'layouts/flash',
                                                  locals: { flash: { notice: t('flash.tickets.deleted_notice') } })

          # The delete button sits in the writing surface (turbo-frame#writing_surface); close it.
          streams << turbo_stream.update('writing_surface', '')

          # Collapse the content column (script partial, S4).
          streams << turbo_stream.append_all('body', partial: 'organisations/tickets/destroy_close')

          render turbo_stream: streams
        end

        format.html do
          redirect_to organisation_project_tickets_path(@current_organisation, @project),
                      notice: t('flash.tickets.deleted')
        end
      else
        format.turbo_stream do
          render turbo_stream: turbo_stream.prepend(
            'flash',
            partial: 'layouts/flash',
            locals: { flash: { alert: t('flash.tickets.delete_error') } }
          )
        end

        format.html do
          redirect_to organisation_project_tickets_path(@current_organisation, @project, ticket_id: ticket_id),
                      alert: t('flash.tickets.delete_error')
        end
      end
    end
  rescue StandardError => e
    Rails.logger.error "Error deleting the task: #{e.message}"

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.prepend(
          'flash',
          partial: 'layouts/flash',
          locals: { flash: { alert: t('flash.tickets.delete_error_detail', error: e.message) } }
        )
      end

      format.html do
        redirect_to organisation_project_tickets_path(@current_organisation, @project, ticket_id: @ticket.id),
                    alert: t('flash.tickets.delete_error_detail', error: e.message)
      end
    end
  end

  # GET /projects/:project_id/tickets/:id/move_preflight
  #
  # Returns the move modal or the impact preview for a target project.
  # Without target_project_id: renders the full modal.
  # With target_project_id: renders only the impact turbo-frame.
  def move_preflight
    authorize @ticket, :move?

    # Available target projects: all active projects in the org, except the current one
    @target_projects = policy_scope(Project)
                       .active
                       .where.not(id: @project.id)
                       .order(:name)

    if params[:target_project_id].present?
      @target_project = @target_projects.find_by(id: params[:target_project_id])

      if @target_project.nil?
        render partial: 'organisations/tickets/move_ticket_impact',
               locals: { error: I18n.t('move_ticket.no_write_access'), impact: nil },
               layout: false
        return
      end

      # Check write access to the target project
      unless policy(@target_project).area_access?(:tickets, :write)
        render partial: 'organisations/tickets/move_ticket_impact',
               locals: { error: I18n.t('move_ticket.no_write_access'), impact: nil },
               layout: false
        return
      end

      actor = Actors::MoveTicket.new(ticket: @ticket, target_project: @target_project, current_user: current_user)
      @impact = actor.preflight

      render partial: 'organisations/tickets/move_ticket_impact',
             locals: { error: nil, impact: @impact },
             layout: false
    else
      render partial: 'organisations/tickets/move_ticket_modal',
             locals: { ticket: @ticket, target_projects: @target_projects },
             layout: false
    end
  end

  # POST /projects/:project_id/tickets/:id/move
  #
  # Moves a ticket to another project.
  def move
    authorize @ticket, :move?

    target_project = Project.find_by(id: params[:target_project_id])

    unless target_project
      redirect_to organisation_project_tickets_path(@current_organisation, @project, ticket_id: @ticket.id),
                  alert: I18n.t('move_ticket.error', error: t('flash.tickets.target_project_not_found')) and return
    end

    unless policy(target_project).area_access?(:tickets, :write)
      redirect_to organisation_project_tickets_path(@current_organisation, @project, ticket_id: @ticket.id),
                  alert: I18n.t('move_ticket.no_write_access') and return
    end

    actor = Actors::MoveTicket.new(ticket: @ticket, target_project: target_project, current_user: current_user)
    result = actor.call

    if result.success?
      redirect_to organisation_project_tickets_path(@current_organisation, target_project, ticket_id: @ticket.id),
                  notice: I18n.t('move_ticket.success', project_name: target_project.name)
    else
      redirect_to organisation_project_tickets_path(@current_organisation, @project, ticket_id: @ticket.id),
                  alert: I18n.t('move_ticket.error', error: result.errors.join(', '))
    end
  end

  # PATCH /projects/:project_id/tickets/:id/update_kanban_attribute
  # ONE change of the registry to THIS ticket: a drop on the Kanban board, and
  # the inline menus of the ticket head (status, priority, a select attribute,
  # and since 09.09.2026 the assignees). The name is the board's, the job is
  # the head's too; the two doors it had were one door.
  #
  # Sets ONLY the named field through Actors::ApplyTicketChanges with a set
  # of one (doc/ticket_bulk_edit_plan.md, D13): the change registry validates the
  # value against the field's options and DELIBERATELY skips full model validation,
  # so a legacy-invalid neighbour attribute cannot block the single-attribute write.
  # A drop into the "unset" column arrives as value null and becomes a clear. The
  # actor's coded failure maps back to the Kanban JSON contract (error/success
  # shapes the board JS depends on).
  def update_kanban_attribute
    authorize @ticket, :update?

    result = Actors::ApplyTicketChanges.call(
      project: @project, ticket_ids: [@ticket.id], changes: [registry_change_from_params], current_user: current_user
    )

    unless result.success?
      Rails.logger.warn "[KANBAN] #{result.code}: #{result.errors.join(', ')}"
      render json: { error: result.errors.first, code: result.code }, status: :unprocessable_entity
      return
    end

    @ticket.reload

    respond_to do |format|
      format.turbo_stream do
        streams = []

        # Replace the Kanban card (for the Kanban board)
        streams << turbo_stream.replace(
          "kanban-card-#{@ticket.id}",
          partial: 'organisations/tickets/kanban_card',
          locals: { ticket: @ticket, project: @project, organisation: @current_organisation }
        )

        # Replace the ticket head (desktop + mobile), but only in a display of
        # THIS ticket. The action does not know which ticket the browser has
        # open and must not start to; the selector decides where the head
        # lands. Unscoped, "open A, drag B" put B's head over A's comments and
        # history (doc/kanban_ticket_als_bahn_plan.md, section 4.6, S0).
        # _ticket_display wraps every display in [data-ticket-id]; a display
        # of another ticket has no target and nothing is replaced.
        head_of_this_ticket = "[data-ticket-id='#{@ticket.id}'] #ticket-header"
        streams << turbo_stream.replace_all(
          "#ticket_display_frame #{head_of_this_ticket}",
          partial: 'organisations/tickets/ticket_header_show',
          locals: { ticket: @ticket, current_organisation: @current_organisation, project: @project }
        )

        # Replace the ticket row in the list (and its parent's, see TicketListColumns)
        streams.concat(ticket_list_row_streams(@ticket, columns: ticket_list_columns(@project)))

        render turbo_stream: streams
      end
      format.json { render json: { success: true } }
    end
  end

  private

  # The registry's two shapes (Tickets::Changes), told apart by the parameters:
  # a single field takes a value, or a clear when the value is null; a
  # multi-valued field (the assignees, from the head's people menu) takes the
  # people to add and the people to remove, the difference the menu computed
  # against what it showed when it opened, so two people changing one ticket
  # do not overwrite each other's ticks.
  def registry_change_from_params
    change = { 'field' => params[:attribute_name].to_s }
    if params.key?(:add) || params.key?(:remove)
      change.merge('add' => Array(params[:add]), 'remove' => Array(params[:remove]))
    else
      change.merge(params[:value].nil? ? { 'clear' => true } : { 'value' => params[:value] })
    end
  end

  # Only tickets use the full-page mobile boundary; other lists still use 768px.
  def set_viewport_mode
    params[:viewport] ||= request.headers['X-Viewport'] if request.headers['X-Viewport'].in?(VIEWPORT_MODES)
    super
  end

  # Where the writing surface was opened from; decides the
  # success response of #create. Read from the form's hidden field or the open link.
  def writing_surface_source
    source = params[:source] || params[:ticket]&.[](:source)
    %w[index_page dashboard kanban mobile_detail].include?(source) ? source : 'index_page'
  end

  # "+ Ticket" in a kanban column preselects that column's value in the form.
  # Whitelisted: only an existing select definition and one of its allowed values.
  def apply_kanban_preset(ticket)
    name = params[:preset_attribute].presence
    value = params[:preset_value].presence
    return unless name && value

    definition = ticket.attribute_definitions.find { |ad| ad.name == name && ad.field_type == 'select' }
    return unless definition&.allowed_values&.any? { |opt| opt['value'] == value }

    ticket.set_custom_attribute(name, value)
  end

  def load_ticket_notification_counts
    @unread_notifications_per_ticket = current_user.notifications
                                                   .channel_in_app
                                                   .unread
                                                   .where(notifiable_type: 'Ticket', project_id: @project.id)
                                                   .group(:notifiable_id)
                                                   .count
  end

  # Override from ObjectListController - we use set_ticket instead
  def should_set_object?
    false
  end

  # Optimized includes for ticket lists to avoid N+1 queries.
  # assignees carry their avatar blob: the rows render the name circles in
  # circle mode, whose attached? check is one query per assignee otherwise.
  def optimized_ticket_includes
    [
      :creator,
      { assignees: { avatar_attachment: :blob } },
      :tags,
      :ticket_assignments,
      { ticket_assignments: :user },
      { project: :ticket_attribute_definitions }
    ]
  end

  # Optimized includes for ticket detail views
  def optimized_ticket_detail_includes
    [
      :tags,
      :creator,
      :rich_text_content,
      { assignees: { avatar_attachment: :blob } },
      # No posts: the timeline loads them through Post.readable_by, and a preload
      # would carry the private ones of other people
      { time_sessions: :creator },
      { project: :ticket_attribute_definitions }
    ]
  end

  def set_view_configuration
    @view_configuration = ViewConfiguration.for_user_project(current_user, @project, 'tickets')
    @available_columns = @view_configuration.available_columns
    @view_mode = @viewport_mode == 'mobile' ? 'table' : @view_configuration.view_mode
    @view_mode = 'table' unless ViewConfiguration::VIEW_MODES.include?(@view_mode)

    # Kanban: resolve the attribute, fall back to table if none present
    if @view_mode == 'kanban'
      @kanban_attribute = @view_configuration.resolved_kanban_attribute
      @view_mode = 'table' unless @kanban_attribute
    end

    # The active folder (through the policy scope), its dissolver result for the
    # filter bar, and the ONE column list of this list: the folder's or the base
    # view's (doc/spaltenwahl_plan.md, S1).
    @active_smart_folder = active_folder_record
    @dissolver_result = dissolved_active_view if @active_smart_folder
    @columns = Tickets::ResolveColumns.call(view_configuration: @view_configuration, smart_folder: @active_smart_folder)
  end

  def log_query_performance(_query)
    # Intentionally empty - debug logging removed for production
  end

  def set_ticket
    @ticket = @project.tickets
                      .includes(optimized_ticket_detail_includes)
                      .find(params[:id])
    @object = @ticket # For ObjectListController compatibility
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = t('flash.tickets.not_found')

    # For Turbo Frame requests, return 404 instead of redirect to avoid undefined URLs
    if turbo_frame_request?
      head :not_found
      return
    end

    # Validate that all variables needed for the redirect are present
    unless @current_organisation&.id && @project&.id
      Rails.logger.error "Missing organisation or project for redirect: org=#{@current_organisation&.id}, project=#{@project&.id}"
      redirect_to root_path and return
    end

    redirect_to organisation_project_tickets_path(@current_organisation, @project) and return
  end

  def set_tickets
    @tickets = @project.tickets.order(created_at: :desc)
  end

  # ONE builder for the board, two callers (index, and show for a full page in
  # kanban mode), fed by the same filter pipeline as the list. `selected:` is
  # the open ticket: the presenter guarantees its card across both caps (D3
  # of doc/kanban_ticket_als_bahn_plan.md).
  def build_kanban_board(scope, selected: nil)
    presenter = KanbanBoardPresenter.new(scope, @kanban_attribute, selected: selected)
    @kanban_columns = presenter.columns
    @kanban_capped = presenter.capped?
    @kanban_total = presenter.total_in_scope
    presenter
  end

  def ticket_lane_frame_request?
    turbo_frame_request? && turbo_frame_request_id == detail_frame_id
  end

  def ticket_params
    # Get base permitted params. parent_id is attacker-controllable; the same-project /
    # one-level guards live in the Ticket model validations, not in this filter.
    permitted = [:title, :content, :tag_list, :ticket_type, :parent_id, { assignee_ids: [] }]

    # Ticket document handling
    permitted << { ticket_document_files: [] }
    permitted << { remove_document_ids: [] }

    # Add custom_attributes if present
    permitted << { custom_attributes: params[:ticket][:custom_attributes].keys } if params[:ticket][:custom_attributes].present?

    params.require(:ticket).permit(permitted)
  end

  def search_params
    params.permit(:search)
  end

  # Checks whether the user has write permission for the ticket area
  # The changes as the panel sends them: a JSON array, or the same as form
  # fields indexed by position (changes[0][field]), which Rails reads as a hash.
  # The selection as the panel names it (mode ids or all), resolved against
  # the same filtered_objects the table paginates.
  def resolve_bulk_selection
    Tickets::BulkSelection.call(
      scope: policy_scope(@project.tickets),
      selection: params[:selection],
      filtered_relation: -> { filtered_objects }
    )
  end

  # The target of a bulk move: an active project of the organisation the
  # reader may see, never this one.
  def bulk_target_project
    return nil if params[:target_project_id].blank?

    policy_scope(Project).active.where.not(id: @project.id).find_by(id: params[:target_project_id])
  end

  def bulk_changes_params
    raw = params[:changes]
    return [] if raw.blank?
    return raw.map { |entry| entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry.to_h } if raw.is_a?(Array)

    raw.to_unsafe_h.values
  end

  def bulk_stock_params
    raw = params[:stock]
    raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : {}
  end

  # After a run: the list for the current address, and the result line.
  def render_bulk_run(run)
    @pagy, @objects = paginate(filtered_objects)
    @tickets = @objects
    @columns = ticket_list_columns(@project)
    # update, not replace: the target is the frame ELEMENT, and a replace
    # would swap it for the partial's own root and take the frame's id with it.
    render turbo_stream: [
      turbo_stream.update(results_frame_id, partial: results_partial_path, locals: build_results_locals),
      turbo_stream.update('ticket-selection-result',
                          partial: 'organisations/tickets/bulk_result', locals: { run: run, project: @project })
    ]
  end

  def render_bulk_refusal(code, messages = [])
    render turbo_stream: turbo_stream.update('ticket-selection-result',
                                             partial: 'organisations/tickets/bulk_refusal',
                                             locals: { code: code, messages: messages }),
           status: :unprocessable_content
  end

  def authorize_ticket_write
    return if policy(@project).area_access?(:tickets, :write)

    flash[:alert] = t('flash.tickets.no_edit_permission')
    redirect_to organisation_project_tickets_path(@current_organisation, @project) and return
  end

  # Special permission check for deleting tickets
  # Deleting tickets additionally requires the 'delete_tickets' permission
  def authorize_ticket_deletion
    return if policy(@ticket).destroy?

    flash[:alert] = t('flash.tickets.no_delete_permission')
    redirect_to organisation_project_tickets_path(@current_organisation, @project, ticket_id: @ticket.id) and return
  end

  # --- create_summary: response preparation ---

  def render_summary_failure(message)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.prepend('flash',
                                                  partial: 'layouts/flash',
                                                  locals: { flash: { alert: message } })
      end
      format.html do
        flash[:alert] = message
        redirect_back(fallback_location: organisation_project_tickets_path(current_organisation, @project))
      end
    end
  end

  def render_summary_save_failed
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.prepend('flash',
                                                  partial: 'layouts/flash',
                                                  locals: { flash: { alert: t('flash.tickets.summary_error') } })
      end
      format.html do
        redirect_to organisation_project_tickets_path(@current_organisation, @project, ticket_id: @ticket.id),
                    alert: t('flash.tickets.summary_error')
      end
    end
  end

  def render_summary_success
    respond_to do |format|
      format.turbo_stream do
        @post = Post.new

        # Update the content frame (timeline lazy-loads via turbo-frame)
        render turbo_stream: [
          turbo_stream.update(
            'ticket_display_frame',
            partial: 'organisations/tickets/ticket_content_for_frame',
            locals: { ticket: @ticket, post: @post, project: @project }
          ),
          *ticket_list_row_streams(@ticket, columns: ticket_list_columns(@project)),
          turbo_stream.prepend('flash',
                               partial: 'layouts/flash',
                               locals: { flash: { notice: t('flash.tickets.summary_created') } })
        ]
      end

      format.html do
        redirect_to organisation_project_tickets_path(@current_organisation, @project, ticket_id: @ticket.id),
                    notice: t('flash.tickets.summary_created')
      end
    end
  end
end
