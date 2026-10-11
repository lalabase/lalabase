# frozen_string_literal: true

class Organisations::TimeSessionsController < Organisations::BaseController
  include ActionView::RecordIdentifier
  include Pageable

  # Utility actions use alternative authorization (policy_scope, inline checks)
  skip_after_action :verify_authorized, only: %i[tickets_for_project]

  # No Sortable here. This list has no sortable columns: its order is fixed
  # (months newest first, inside a month alphabetically by subject) and lives in
  # #row_keys_relation, because paging over rows has to sort in the database.
  # A bookmarked sort[column] would otherwise wrap the grouped query in the
  # DISTINCT FROM-subquery of the concern, and answer with a 500.
  # Pagination – default per page (expected by specs)
  setup_pagination 10

  # Eager loading for one page of bookings: exactly what the row and the booking
  # under it read (ticket/meeting: the row's subject and its link; creator:
  # ==-comparison + full_name; project: the edit and delete links and the project
  # name in the org-wide list; time_session_group: the billing name beside the
  # state; tags: tag_list chips, otherwise `tags.pluck` per row). Prevents N+1.
  # The subject's PROJECT and its organisation come along: the row builds the link
  # to the ticket or meeting from them and asks the area permission about them
  # (time_session_subject_presentation). Preloading only the subject left one
  # projects query and one organisations query PER ROW, which is what
  # "does not grow with the number of rows" in the rows spec now measures.
  ROW_INCLUDES = [
    { ticket: { project: :organisation } },
    { meeting: { project: :organisation } },
    :creator, :project, :time_session_group, :tags
  ].freeze

  # A row of the time list is one subject in one project in one month. These two
  # fragments spell that out for the database; ListRows.month_key_sql is the
  # third piece and lives with the object that reads it back.
  SUBJECTLESS_SQL = '(time_sessions.ticket_id IS NULL AND time_sessions.meeting_id IS NULL)'
  # COLLATE "C" compares byte for byte, which is what Ruby's <=> does after
  # downcase -- so this ORDER BY and TimeSession.subject_sort_key stay ONE order
  # even though one of them runs in Postgres and the other in Ruby.
  SUBJECT_TITLE_SQL = %(lower(COALESCE(tickets.title, meetings.title, projects.name)) COLLATE "C")
  # Rows per page. The cap is this list's own: a row can hold any number of
  # bookings, so 200 rows (the global maximum) is a different amount of work here
  # than it is on a flat list.
  MAX_ROWS_PER_PAGE = 50

  # How many subjects the "Bezug" menu offers at once (review of #693).
  #
  # Its options are server-rendered links inside a <details>, so every one of
  # them is markup the reader pays for on EVERY render of the list -- including
  # the frame answer of a search, which re-renders the filter line and throws it
  # away. Measured before this cap, on ten projects with a hundred tickets each:
  # 1001 links, 634 KB for that one menu, 429 ms of warm render, and 649 KB of
  # it discarded again on every debounced keystroke.
  #
  # A display budget, not a domain rule: fifty options are already more than
  # anyone scrolls past, and there are two ways beyond it -- the project filter,
  # which narrows the SOURCE, and the type-to-narrow field inside the menu.
  MAX_FILTER_SUBJECTS = 50

  # How many bookings the capture popover's review column lists. It is a preview
  # beside the form, not the list — the footer link opens the full list.
  POPOVER_SESSIONS_LIMIT = 10

  # Set by the time list's capture modal (_form_organization_wide): a Turbo save
  # from there is answered with the list page, not with the list stream.
  ANSWER_WITH_PAGE_PARAM = :answer_with_page

  # The two id columns a booking can carry its subject in, as the grouped read
  # below asks for them. TimeSession::SUBJECT_FILTER_PARAMS names the same two
  # as request parameters; these are the columns, and they are deliberately
  # spelled once here rather than derived, because a parameter name and a column
  # name agreeing today is not a reason to make one depend on the other.
  SUBJECT_ID_COLUMNS = %i[ticket_id meeting_id].freeze

  # Not on the index: the project's own list is gone, and a project reaches the
  # one list only as project_id_filter. Resolving ?project_id= there rendered the
  # old project variant of the page through the back door (Zweitreview of #675).
  before_action :set_project_if_present, except: %i[index]
  before_action :set_ticket, only: %i[new create subject_popover]
  before_action :set_meeting, only: %i[new create subject_popover]
  before_action :set_time_session, only: %i[show edit update destroy]
  before_action :authorize_time_session_access, only: %i[index]
  before_action :authorize_time_session_read, only: %i[show]
  before_action :authorize_time_session_write, only: %i[new create]
  before_action :authorize_creator!, only: %i[edit update destroy]

  def index
    # Load available smart folders for TimeSession
    @time_session_smart_folders = policy_scope(SmartFolder)
                                  .where(organisation_id: current_organisation.id)
                                  .where('target_object_type = ? OR target_object_type = ?', 'TimeSession', 'All')

    @time_session_smart_folders = @time_session_smart_folders.order(:name)

    # Load only accessible projects for the filter
    @accessible_projects = load_accessible_projects

    # Load only TimeSessionGroups with accessible TimeSessions for the filter
    @accessible_time_session_groups = load_accessible_time_session_groups

    # Load all available tags of the organisation for the new modal
    @available_tags = policy_scope(Tag).order(:name).distinct.pluck(:name)

    # Two views of one page (user, 01.09.2026): the list, or the status table
    # of booked time per project IN ITS PLACE, over the period it is showing.
    # The table is gated like it always
    # was (TimeSessionStatisticsPolicy); without the right, view=overview is
    # the list. The overview needs nothing of the list below, so it stops here.
    @view = overview_view? ? 'overview' : 'list'
    if @view == 'overview'
      # ONE period for the whole table, all columns at once (D3): a period on a
      # single column would make the row untrue, because the total would stop
      # being the sum of its cells. Same vocabulary as the list's segments
      # (TimeSessions::ListPeriod), own default: the table answers "alles" until
      # somebody narrows it, so old unbilled hours stay visible.
      @table_period = TimeSessions::ListPeriod.normalize_for_table(params[:date_range])
      table_start, table_end = TimeSessions::ListPeriod.bounds_for(@table_period)
      @project_statistics = TimeSessionStatisticsService.new(
        organisation: current_organisation,
        viewing_scope: organisation_viewing_scope,
        start_date: table_start,
        end_date: table_end
      ).calculate_project_statistics
      return
    end

    # Initialize base query
    base_query = nil

    # If a smart folder was given, apply its filters
    if params[:smart_folder_id].present?
      begin
        @active_smart_folder = policy_scope(SmartFolder).find(params[:smart_folder_id])

        # Check whether the smart folder is configured for TimeSessions
        if %w[TimeSession All].include?(@active_smart_folder.target_object_type)
          # Use the SmartFolderService to get the filtered TimeSessions
          service = SmartFolderService.new(@active_smart_folder, current_user)
          folder_results = service.fetch_results

          # Filter the results down to TimeSessions
          if folder_results[:items].is_a?(ActiveRecord::Relation) && folder_results[:items].klass == TimeSession
            base_query = folder_results[:items]
          else
            time_session_ids = folder_results[:items]
                               .select { |item| item.is_a?(TimeSession) }
                               .map(&:id)
            base_query = TimeSession.where(id: time_session_ids)
          end
        end
      rescue ActiveRecord::RecordNotFound
        # Smart folder not found, back to the default view
        flash[:alert] = t('flash.time_sessions.smart_folder_not_found')
        redirect_to helpers.time_list_path(@current_organisation) and return
      end
    end

    # If no smart folder or an invalid smart folder, use the default query.
    # Visibility guard: the smart-folder branch must run through the same
    # TimeSessionPolicy::Scope as the default path (find_time_sessions scopes
    # internally) — otherwise a can_view_own user sees foreign sessions via
    # folder results.
    base_query = base_query.nil? ? find_time_sessions : policy_scope(base_query)

    # Default status filter: in_billing + without_billing (NOT 'billed') — the typical
    # use case is "what is still pending billing?". Already billed sessions are hidden
    # by default; the user can DELIBERATELY add 'billed'.
    # Intersected with the constant, not taken raw: status_filters[]=foo activated
    # no pill while the list stayed unfiltered (apply_billing_status_filter only
    # looks for the three names it knows), and _filter_selects carries the junk
    # value along on every submit. Duplicates were the same hole from the other
    # side: four entries make filters.size < 3 false and the filter drops out.
    submitted_status_filters = Array(params[:status_filters]) & TimeSession::BILLING_STATUS_FILTERS
    @effective_status_filters = if submitted_status_filters.any? || params[:billing_status].present?
                                  submitted_status_filters
                                else
                                  TimeSession::DEFAULT_STATUS_FILTERS
                                end

    # "Specific billing" picker: tailored to the status filter. The other side
    # of that rule, whether the picker is shown at all and what a choice takes
    # with it, is TimeSessionsHelper#time_billing_choice_locked? and
    # #time_billing_choice_owns.
    @accessible_time_session_groups = if @effective_status_filters.include?('billed') && @effective_status_filters.include?('in_billing')
                                        @accessible_time_session_groups
                                      elsif @effective_status_filters.include?('billed')
                                        @accessible_time_session_groups.billed
                                      elsif @effective_status_filters.include?('in_billing')
                                        @accessible_time_session_groups.unbilled
                                      else
                                        @accessible_time_session_groups.none
                                      end

    # Additionally filter by project when a project is selected
    # (billings that contain sessions of the project).
    active_project_id = params[:project_id_filter].presence
    if active_project_id.present?
      @accessible_time_session_groups = @accessible_time_session_groups
                                        .joins(:time_sessions)
                                        .where(time_sessions: { project_id: active_project_id })
                                        .distinct
    end

    # The period, from ONE owner (TimeSessions::ListPeriod): the eight preset
    # keys, their order, their labels and their windows. The status table above
    # the list reads the same owner, so a cell cannot promise a window the list
    # it opens does not apply. The default is this month, and it is declared
    # there (LIST_DEFAULT) rather than in a comment that can go stale -- this
    # one said "last 30 days" for a while.
    #
    # Hand-typed bounds win over a preset key: typing a date IS choosing
    # "eigener Zeitraum", whatever the address still says.
    custom_dates_set = params[:start_date].present? || params[:end_date].present?
    @effective_date_range = if custom_dates_set
                              TimeSessions::ListPeriod::CUSTOM
                            else
                              TimeSessions::ListPeriod.normalize_for_list(params[:date_range])
                            end

    if @effective_date_range == TimeSessions::ListPeriod::CUSTOM
      # ONE rule for a typed bound (TimeSessions::DateBound): junk, an array, a
      # five-digit year are no bound, which is the answer the filter service
      # gives such a value anyway. The raw parameter used to travel on from here
      # into the empty state's label, which called .to_date on it and answered
      # ?start_date=gestern&end_date=2026-07-31 with a 500 (Zweitreview of S3).
      @effective_start_date = TimeSessions::DateBound.call(value: params[:start_date])
      @effective_end_date   = TimeSessions::DateBound.call(value: params[:end_date])
    else
      @effective_start_date, @effective_end_date = TimeSessions::ListPeriod.bounds_for(@effective_date_range)
    end

    # Every filter EXCEPT the billing status. Built once and used twice: once to
    # count the three states, once (with the status added back) for the list.
    # The plain filters come off the request by their declaration
    # (TimeSessions::ListFilters); the period arrives resolved into bounds.
    filters_except_status = TimeSessions::ListFilters.plain_attributes_from(params).merge(
      start_date: @effective_start_date&.to_s,
      end_date: @effective_end_date&.to_s,
      smart_folder: @active_smart_folder,
      # Not a filter: the tickets the ticket phase may read (TicketPolicy).
      readable_tickets: policy_scope(Ticket)
    )

    # The figure on each status pill, in ONE grouped query (S2 of the filter-line
    # plan). What the pill SHOWS is hours; the booking count that comes with it
    # decides only whether a state is empty. Hours because they add up: minutes
    # belong to exactly one state, so the active pills together are exactly the
    # sum box under the filter. A count of bookings lines up with nothing the page
    # prints -- the footer counts ROWS (one subject in one month) -- and a count
    # of rows would overlap, because a row can hold two states at once.
    #
    # The rule that makes the numbers trustworthy (F4): a count runs under every
    # active filter EXCEPT the status filter. Counted with it, the page would
    # print "5" beside a pill and then show nothing, or print three numbers whose
    # sum contradicts the list under them. Without any filter at all it would
    # print 7 + 6 + 7 next to an empty list, which is the mock the design review
    # reproduced. The states are mutually exclusive, so dropping the status
    # filter entirely and grouping is the same thing as excluding each pill's own
    # state from its own count, in one query instead of three.
    #
    # billing_status (the legacy single-value param) is a status filter too and
    # is dropped with it, or the count would silently inherit it.
    @status_counts = TimeSessions::BucketTotals.call(
      scope: TimeSessionFilterService.new(base_query: base_query, **filters_except_status,
                                          status_filters: nil, billing_status: nil).call
    )

    # The list's filters, all of them, in ONE hash. Not spread over the call
    # below any more, because the empty state has to be able to switch each of
    # them off again on its own (TimeSessions::EmptyReason).
    list_filters = filters_except_status.merge(
      billing_status: params[:billing_status],
      status_filters: @effective_status_filters
    )

    # base_query stays the UNFILTERED base from here on: it is the second half
    # of the diagnosis below, which asks what each filter is hiding.
    list_query = TimeSessionFilterService.new(base_query: base_query, **list_filters).call

    # The total of ALL filtered sessions, before pagination.
    #
    # ⚠️ Always. The result row above the list states
    # "n Zeiten · HH:MM" on every render since the layout of 02.09.2026, so the
    # figure is no longer optional; asking for it conditionally printed 00:00
    # beside an honest count, which is worse than not printing it at all. The
    # price is one aggregate per index render.
    #
    # NOT base_query.sum(:duration): the list query is .distinct (join dedup) and
    # Rails folds that into SUM(DISTINCT duration), which collapses EQUAL values
    # — two 60-minute rows summed to 60. Summing over the id subquery dedups
    # rows, not values. reorder(nil) because a sorted DISTINCT subquery would
    # demand its ORDER BY columns in the select list (Postgres).
    # ⚠️ COUNT and SUM in one pass, and the count is of BOOKINGS.
    # The result row says "n Zeiten", and pagy.count is the number of ROWS -- one
    # subject in one month, which is what the page paginates. Reading the row
    # count and calling it Zeiten was right only by accident, on data where every
    # row held exactly one booking.
    @total_filtered_count, @total_filtered_duration =
      TimeSession.where(id: list_query.reorder(nil).select(:id))
                 .pick(Arel.sql('COUNT(*), COALESCE(SUM(duration), 0)'))

    # A page of ROWS, not of bookings. A row is one subject in one project in one
    # month. Paginating over bookings cuts a month in half and then prints the
    # fragment under that month's name and sum.
    @list_months, @pagy, @time_sessions = load_row_page(list_query)

    # An empty list has to name the filter that emptied it (F5), and it can only
    # be asked once the answer is known to be empty: the question costs one
    # EXISTS per active filter.
    #
    # The first-use half of the condition is about that cost alone. _index_table
    # picks the explainer over the diagnosis whatever this holds, so dropping it
    # would change no page -- it would only run seven queries for a page that
    # cannot show their answers. Pinned in the request spec, or it would be
    # invisible to the suite.
    # Who the four id filters point at, and the one hash every surface reads
    # them through. Loaded on EVERY render of the list since S7, because the
    # filter line prints their names; before it, they were looked up inside the
    # diagnosis below and only for the filters that had actually emptied the
    # list, which is all the empty state ever needed.
    @filter_people = load_filter_people
    @filter_tags = load_filter_tags
    # Step 3a (E5): the ticket phase is offered while the reader sees any
    # booking on a ticket they may open. Without one every phase answers empty.
    @filter_offers_ticket_phase = visible_time_sessions_scope.where(ticket_id: policy_scope(Ticket).select(:id)).exists?
    load_filter_selection
    @filter_state = build_filter_state

    # The subjects the filter line offers (S7, D4). Down here, not beside the
    # projects above: the overview view returns before this point and renders
    # only the status table, which has no subject control at all -- two
    # subqueries and a preload for a page that cannot show their answers.
    @filter_subjects, @filter_subjects_capped = load_filter_subjects

    # ⚠️ The diagnosis only DIAGNOSES now. It used to look the four named records
    # up itself, guarded by which filters it had just blamed -- correct while the
    # empty state was its only reader, and half the answer once the filter line
    # needed the same names on a list that is not empty. load_filter_selection
    # above owns that.
    diagnose_empty_list = @list_months.blank? && !time_sessions_first_use?
    @empty_reason = TimeSessions::EmptyReason.call(base_query: base_query, filters: list_filters) if diagnose_empty_list

    # Use the extended respond_to_sort_and_paginate method
    respond_to_sort_and_paginate(
      @pagy,
      @time_sessions,
      'time_sessions_list_frame',
      'organisations/time_sessions/index_table',
      {
        months: @list_months,
        show_creator: params[:show_creator] == '1'
      }
    )
  end

  def show
    authorize @time_session

    if turbo_frame_request? && params[:frame] == 'content'
      frame_id = params[:frame_id].presence || 'time_session_display_frame'
      render html: helpers.turbo_frame_tag(frame_id) {
        helpers.render(partial: 'organisations/time_sessions/time_session_content_for_frame',
                       locals: { time_session: @time_session, project: @project })
      }, layout: false
      return
    end

    respond_to do |format|
      format.html
      format.turbo_stream do
        if params[:frame] == 'content'
          # Return content for display in the main frame
          render turbo_stream: turbo_stream.update(
            'time_session_display_frame',
            partial: 'organisations/time_sessions/time_session_content_for_frame',
            locals: { time_session: @time_session, project: @project }
          )
        else
          # Standard turbo_stream response
          render
        end
      end
    end
  end

  def new
    if @project.present?
      @time_session = @project.time_sessions.build
      @time_session.ticket = @ticket if @ticket.present?

      # Load all tickets of the project for the dropdown list
      @tickets = @project.tickets.order(:title)
    else
      @time_session = TimeSession.new
    end

    authorize @time_session

    # Load TimeSessionGroups for the dropdown (organisation-wide, only unbilled)
    @time_session_groups = TimeSessionGroup.unbilled.ordered

    # Load all available tags of the organisation
    @available_tags = policy_scope(Tag).order(:name).distinct.pluck(:name)

    respond_to do |format|
      format.html do
        render partial: 'organisations/time_sessions/form',
               locals: { time_session: @time_session, project: @project, ticket: @ticket }
      end
    end
  end

  # The two-column capture popover behind the hours sum in the ticket/meeting
  # header (?ticket_id= or ?meeting_id=, plus project_id): form on the left when
  # the reader may write, the subject's booked time on the right through the
  # reader's own viewing scope. The chip renders an empty lazy turbo-frame
  # pointing here, so the header render never pays for this list.
  def subject_popover
    @popover_subject = @ticket || @meeting
    raise ActiveRecord::RecordNotFound if @popover_subject.nil?

    authorize @popover_subject, :show?
    unless policy(@project).area_access?(:time_sessions, :read) ||
           policy(@project).area_access?(:time_sessions, :write)
      raise Pundit::NotAuthorizedError, query: :subject_popover?, record: @popover_subject
    end

    load_subject_popover_data
    # ?edit=<id> loads a listed row into the form (edit mode). Only listed rows
    # are clickable, so the lookup goes over what the popover shows — anything
    # else (billed, foreign creator, unknown id) falls back to the new-entry
    # form instead of erroring.
    if params[:edit].present?
      candidate = @popover_sessions.find { |session| session.id == params[:edit] }
      @popover_time_session = candidate if candidate && helpers.subject_popover_row_editable?(candidate)
    end
    render partial: 'organisations/time_sessions/subject_popover_frame'
  end

  def create
    @time_session = build_time_session
    authorize @time_session
    ensure_valid_subject
    ensure_valid_occurred_on

    # The actor owns the write: save + group assignment in ONE transaction with
    # the billed guard (T3). build_time_session/ensure_valid_* stay controller
    # concerns (request parsing, D-T3-1) — attributes already sit on the record.
    result = Actors::SaveTimeSession.call(
      time_session: @time_session, attributes: {},
      group_change: group_change_from_params, current_user: current_user
    )

    respond_to do |format|
      if result.success?
        format.turbo_stream do
          # The time list's capture modal is answered with the list page, as it
          # was before it went through Turbo: the list re-render below ignores
          # the filters in the address (create.turbo_stream.erb, "Known gap").
          next redirect_after_success(status: :see_other) if params[ANSWER_WITH_PAGE_PARAM].present?

          # Load data for the success response
          load_time_sessions_for_index if params[:context] == 'index_page'
          load_subject_popover_data if params[:context] == 'subject_popover'
          render status: :ok
        end
        format.html { redirect_after_success }
      else
        apply_save_failure(result)
        # Load necessary data for the form
        @tickets = @project.tickets.order(:title) if @project.present?
        @time_session_groups = TimeSessionGroup.unbilled.ordered

        format.turbo_stream do
          if params[:context] == 'subject_popover'
            # Re-render the popover with the errored record in the form column.
            @popover_time_session = @time_session
            load_subject_popover_data
          end
          # Render the create.turbo_stream.erb template
          render status: :unprocessable_entity
        end
        format.html do
          render partial: 'organisations/time_sessions/form',
                 locals: { time_session: @time_session, project: @project, ticket: @ticket },
                 status: :unprocessable_entity
        end
      end
    end
  end

  def edit
    authorize @time_session, :update?

    # If ticket_id is in params, make sure it is set
    if params[:ticket_id].present?
      @ticket = begin
        @project.tickets.find(params[:ticket_id])
      rescue StandardError
        nil
      end
      @time_session.ticket = @ticket if @ticket.present?
    end

    # Load all tickets of the project for the dropdown list
    @tickets = @project.tickets.order(:title) if @project.present?

    # Load TimeSessionGroups for the dropdown (organisation-wide, only unbilled)
    @time_session_groups = TimeSessionGroup.unbilled.ordered

    # Load all available tags of the organisation
    @available_tags = policy_scope(Tag).order(:name).distinct.pluck(:name)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: (turbo_stream.replace(dom_id(@time_session)) do
          render partial: 'organisations/time_sessions/form', locals: { time_session: @time_session, ticket: @ticket, project: @project }
        end)
      end
      format.html do
        # Check if it's a Turbo Frame request
        if turbo_frame_request?
          render partial: 'organisations/time_sessions/form_index', locals: { time_session: @time_session, project: @project, ticket: @ticket }
        else
          render partial: 'organisations/time_sessions/form', locals: { time_session: @time_session, project: @project, ticket: @ticket }
        end
      end
    end
  end

  def update
    authorize @time_session, :update?
    move_to_requested_project

    # Validate and set the subject (ticket OR meeting) before we call the actor
    ensure_valid_subject

    # The actor owns the write: attributes + group transition in ONE transaction
    # with both billed guards (T3). The project and the subject ids are resolved
    # above against scoped lookups — passing the raw ids again would overwrite
    # that resolution (cross-tenant guard); the group rides in group_change.
    result = Actors::SaveTimeSession.call(
      time_session: @time_session,
      attributes: time_session_params.except(:time_session_group_id, :ticket_id, :meeting_id, :project_id),
      group_change: group_change_from_params, current_user: current_user
    )

    if result.success?
      # Successfully updated - always set a flash message. Not for the capture
      # popover: its feedback happens where the click was, and a persistent
      # flash would pop up on the NEXT navigation instead.
      flash[:notice] = t('flash.time_sessions.updated') unless params[:context] == 'subject_popover'

      respond_to do |format|
        format.html { redirect_to redirect_path_after_update }

        format.turbo_stream do
          if params[:context] == 'index_page'
            # Full refresh repaints the list and closes the modal; the
            # persistent flash above survives the reload (T1 pattern
            # bulk_assign_group — no inline <script> any more).
            render turbo_stream: turbo_stream.refresh
          elsif params[:context] == 'subject_popover'
            # Back to the new-entry form, list and sums re-rendered fresh.
            @popover_subject = @time_session.ticket || @time_session.meeting
            load_subject_popover_data
            render partial: 'organisations/time_sessions/subject_popover_streams'
          else
            # Use the update.turbo_stream.erb template
            render :update
          end
        end
      end
    else
      apply_save_failure(result)

      # Failed - render depending on the format
      respond_to do |format|
        format.turbo_stream do
          if params[:context] == 'subject_popover'
            # Keep the popover open, form in edit mode around the errored record.
            @popover_subject = @time_session.ticket || @time_session.meeting
            @popover_time_session = @time_session
            load_subject_popover_data
            render turbo_stream: turbo_stream.update(
              "subject_time_popover_#{@popover_subject.id}",
              partial: 'organisations/time_sessions/subject_popover'
            ), status: :unprocessable_entity
          else
            render turbo_stream: (turbo_stream.replace(dom_id(@time_session)) do
              render partial: 'organisations/time_sessions/form', locals: { time_session: @time_session, ticket: @ticket }
            end)
          end
        end
        format.html do
          # Load necessary data for the form
          @tickets = @project.tickets.order(:title) if @project.present?
          @time_session_groups = TimeSessionGroup.unbilled.ordered

          render partial: 'organisations/time_sessions/form',
                 locals: { time_session: @time_session, project: @project, ticket: @ticket },
                 status: :unprocessable_entity
        end
      end
    end
  end

  # Refills the org-wide form's ticket select after a project change. Same
  # bounded source as the select rendered with the page (selectable_tickets_for),
  # so the two fillings of one select cannot disagree; the modal sits in every
  # page body, and an unbounded list would be paid on every page load.
  def tickets_for_project
    @project = Project.find(params[:project_id])
    @tickets = policy(@project).area_access?(:tickets, :read) ? helpers.selectable_tickets_for(@project) : []

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.update(
          'ticket_select_container',
          partial: 'organisations/time_sessions/ticket_select',
          locals: { tickets: @tickets, project: @project }
        )
      end
    end
  end

  def bulk_assign_group
    # The right to use the time list, then only the sessions it shows this user,
    # then the admin/own gate. An existing group is checked on its own below.
    authorize TimeSession, :index?
    sessions = policy_scope(TimeSession).where(id: params[:time_session_ids])

    # Admins may assign all sessions, non-admins only their own. This gate stays
    # here unchanged (decision D5; unifying the three divergent assign gates is
    # plan §9.5 backlog) — the actor only performs the write.
    if !current_user.account_admin_in?(current_organisation) &&
       sessions.where.not(creator: current_user).any?
      # redirect_back, not raw request.referer — same reason as respond_bulk_assign
      # below: a cross-host Referer (user-controlled) would raise
      # UnsafeRedirectError (500). Degrades to the fallback.
      redirect_back fallback_location: organisation_time_sessions_path(@current_organisation),
                    alert: t('flash.time_sessions.only_own_groups')
      return
    end

    actor = build_bulk_assign_actor(sessions)
    result = actor.call

    if result.success?
      # Counters were gathered by the actor BEFORE the write (plan §9.8-6).
      set_bulk_assign_flashes(actor.outcome)
      respond_bulk_assign(notice: t('flash.time_sessions.assigned_to_group',
                                    count: actor.outcome.assigned_count, group: result.resource.name))
    else
      respond_bulk_assign(alert: bulk_assign_error_message(result))
    end
  end

  def destroy
    authorize @time_session

    # Save the ticket reference before we delete the session
    @ticket = @time_session.ticket
    # The capture popover needs its subject after the row is gone.
    popover_subject = @time_session.ticket || @time_session.meeting

    if @time_session.creator == current_user
      @time_session.destroy
      respond_to do |format|
        format.turbo_stream do
          if params[:context] == 'subject_popover'
            # Same three answers as saving from the popover: fresh popover,
            # grown-down chip value, reloaded timeline. Never the display frame.
            @popover_subject = popover_subject
            load_subject_popover_data
            next render partial: 'organisations/time_sessions/subject_popover_streams'
          end

          streams = [
            turbo_stream.update('flash') { helpers.render(partial: 'layouts/flash', locals: { flash: { notice: t('flash.time_sessions.deleted') } }) }
          ]

          if params[:context] == 'index_page'
            # Full refresh, the same answer update gives on this page. Removing
            # the row alone leaves everything the deleted booking counted towards
            # standing at its old value: the status pills, the row count and the
            # sum all live OUTSIDE the row that was removed. The persistent flash
            # above survives the reload (T1 pattern bulk_assign_group).
            flash[:notice] = t('flash.time_sessions.deleted')
            return render turbo_stream: turbo_stream.refresh
          else
            # Default behavior: just remove the element
            streams << turbo_stream.remove(@time_session)
          end

          render turbo_stream: streams
        end
        # Redirect based on context
        if params[:project_id].present?
          format.html { redirect_to organisation_project_ticket_path(@current_organisation, @project, @ticket), notice: t('flash.time_sessions.deleted') }
        else
          format.html { redirect_to organisation_time_sessions_path(@current_organisation), notice: t('flash.time_sessions.deleted') }
        end
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.update('flash') { helpers.render(partial: 'layouts/flash', locals: { flash: { alert: t('flash.time_sessions.only_own_delete') } }) }
        end
        # Redirect based on context
        if params[:project_id].present?
          format.html { redirect_to organisation_project_ticket_path(@current_organisation, @project, @ticket), alert: t('flash.time_sessions.only_own_delete') }
        else
          format.html { redirect_to organisation_time_sessions_path(@current_organisation), alert: t('flash.time_sessions.only_own_delete') }
        end
      end
    end
  end

  private

  # Bulk-assign share ONE write path with the popover via the assigner actors.
  # Create-new and existing-group differ only in how the group is resolved; the
  # existing-group find bubbles RecordNotFound as a 404 (tenant scope, plan §9.4).
  def build_bulk_assign_actor(sessions)
    if params[:create_new_group] == 'true'
      Actors::CreateGroupAndAssignTimeSessions.new(
        sessions: sessions, name: params[:new_group_name],
        organisation: current_organisation, current_user: current_user
      )
    else
      # Resolved through the policy scope and checked for update?: a raw id from
      # the form must not reach a group this user may not change.
      group = policy_scope(TimeSessionGroup).find(params[:existing_group_id])
      authorize group, :update?
      Actors::AssignTimeSessionsToGroup.new(sessions: sessions, group: group, current_user: current_user)
    end
  end

  # Same informational flashes as before, now driven by the actor's pre-write
  # counters (identical values, gathered from the exact set the write touches).
  def set_bulk_assign_flashes(outcome)
    flash[:warning] = t('flash.time_sessions.already_assigned', count: outcome.already_assigned_count) if outcome.already_assigned_count.positive?
    return unless outcome.project_names.size > 1

    flash[:info] = t('flash.time_sessions.multi_project',
                     count: outcome.project_names.size, names: outcome.project_names.join(', '))
  end

  # Deliberate triplet with TimeSessionAssignmentsController#assignment_error_message
  # and TimeSessionGroupsController#generate_error_message (same result-code
  # passthrough, different generic fallback per call-site UX). The "unify at the
  # third case" trigger is reached — extract a shared helper when any of the
  # three next changes substantially.
  def bulk_assign_error_message(result)
    case result.code
    when :group_billed, :sessions_billed then result.errors.first
    else t('flash.time_sessions.assign_error', error: result.errors.to_sentence)
    end
  end

  # Preserves the original three-format shape (JS client uses the html redirect
  # and reloads). Flashes are persistent so they survive the redirect / refresh.
  def respond_bulk_assign(notice: nil, alert: nil)
    respond_to do |format|
      format.html do
        # redirect_back, not `redirect_to request.referer || fallback`: the raw
        # referer form raises UnsafeRedirectError (-> 500) on a cross-host
        # Referer header (user-controlled!), while redirect_back degrades to
        # the fallback. Same pattern as the popover controller.
        redirect_back fallback_location: organisation_time_sessions_path(@current_organisation),
                      notice: notice, alert: alert
      end
      format.turbo_stream do
        flash[:notice] = notice if notice
        flash[:alert] = alert if alert
        # turbo_stream.refresh, not .action(:refresh): the latter needs a target
        # and raises on turbo-rails 2.x. The carried-over line was dead (the JS
        # client uses text/html) so it never surfaced — corrected here.
        render turbo_stream: turbo_stream.refresh
      end
      format.any { head(alert ? :unprocessable_entity : :no_content) }
    end
  end

  # Sets the @project and @current_project variables
  def set_project_if_present
    # The org-wide "Zeiten" capture modal carries no project in the route — the chosen
    # project rides inside the form as time_session[project_id]. Resolve either source so
    # authorize_time_session_write checks the real project instead of redirecting on a nil @project.
    project_id = params[:project_id].presence || params.dig(:time_session, :project_id).presence
    return unless project_id

    begin
      @project = Project.find(project_id)
      @current_project = @project
    rescue ActiveRecord::RecordNotFound
      flash[:alert] = t('flash.shared.project_not_found')
      redirect_to organisation_projects_path(@current_organisation) and return
    end
  end

  # Checks whether the user has read permission for the time sessions area
  def authorize_time_session_read
    # For the organisation-wide view we check general membership
    # For the project-specific view we check project permissions
    if @project.present?
      unless policy(@project).area_access?(:time_sessions, :read)
        flash[:alert] = t('flash.time_sessions.no_view_permission')
        redirect_to organisation_project_path(@current_organisation, @project) and return
      end
    else
      # For the organisation-wide view only check membership in the current organisation
      unless current_user.active_member_of_organisation?(@current_organisation)
        flash[:alert] = t('flash.shared.not_member')
        redirect_to organisation_root_path(organisation_id: @current_organisation.id) and return
      end
    end
  end

  # Checks whether the user has write permission for the time sessions area
  def authorize_time_session_write
    # A project must be selected for new TimeSessions
    if @project.nil?
      flash[:alert] = t('flash.time_sessions.select_project')
      redirect_to organisation_time_sessions_path(@current_organisation) and return
    end

    return if policy(@project).area_access?(:time_sessions, :write)

    flash[:alert] = t('flash.time_sessions.no_create_permission')
    redirect_to helpers.time_list_path(@current_organisation, project: @project) and return
  end

  # Deliberate duplication of set_meeting (its twin below). Two subject types only —
  # if a third subject type ever appears, decide then whether to unify. The bodies
  # look alike but scope to different associations (@project.tickets vs .meetings),
  # so they stay explicit rather than sharing a single parametrised helper.
  def set_ticket
    # For "new" from params, for "create" possibly also from time_session_params
    if action_name == 'create' && params[:time_session] && params[:time_session][:ticket_id].present?
      @ticket = begin
        @project.tickets.find(params[:time_session][:ticket_id])
      rescue StandardError
        nil
      end
    elsif params[:ticket_id].present?
      @ticket = begin
        @project.tickets.find(params[:ticket_id])
      rescue StandardError
        nil
      end
    end
  end

  # ⚠️ `meeting_id` carries TWO meanings in this controller, exactly as
  # `ticket_id` already did: on new/create it BINDS the subject of the booking
  # being written (here), on index it FILTERS the list (S6, the
  # TimeSessionFilterService attribute). They never meet -- this runs on
  # new/create only, and the filter is read in index only.
  #
  # Deliberate duplication of set_ticket (its twin above). Two subject types only —
  # if a third subject type ever appears, decide then whether to unify. Loads only
  # through @project.meetings, so a foreign-project/tenant id resolves to nil.
  def set_meeting
    if action_name == 'create' && params[:time_session] && params[:time_session][:meeting_id].present?
      @meeting = begin
        @project.meetings.find(params[:time_session][:meeting_id])
      rescue StandardError
        nil
      end
    elsif params[:meeting_id].present?
      @meeting = begin
        @project.meetings.find(params[:meeting_id])
      rescue StandardError
        nil
      end
    end
  end

  def set_time_session
    if @project.present?
      @time_session = @project.time_sessions.find(params[:id])
    else
      # For organization-wide view, find within the organization's time sessions
      @time_session = TimeSession.find(params[:id])
      # Set the project from the time session for compatibility
      @project = @time_session.project
    end
  end

  def time_session_params
    # :ticket_id and :meeting_id are the two explicit, deliberately separate subject
    # columns (plan decision 2 — no polymorphic subject). ensure_valid_subject scopes
    # each to @project and #at_most_one_subject enforces the XOR.
    params.require(:time_session).permit(:duration_string, :occurred_on, :description, :ticket_id, :meeting_id, :time_session_group_id, :project_id, :tag_list)
  end

  # Unified subject validation for create/update. A session's subject is a Ticket OR
  # a Meeting — never both (see #at_most_one_subject and the DB check constraint).
  # Each id is only touched when its key is actually submitted, so an edit form that
  # carries just one subject cannot silently null the other. Every lookup goes
  # strictly through the booking's own project (after a move: the target), so a
  # tampered id from a foreign project/tenant resolves to "not found" and is
  # cleared (cross-tenant guard).
  def ensure_valid_subject
    return unless params[:time_session]

    assign_subject_from_params(:ticket, @time_session.project.tickets)
    assign_subject_from_params(:meeting, @time_session.project.meetings)
  end

  # A booking may move to another project of the organisation when the reader
  # may edit it there as well (TimeSessionPolicy#update? against the target).
  # The target comes from a tenant-scoped lookup; an unknown or forbidden one is
  # refused like any other missing permission. A fresh policy object on
  # purpose: Pundit caches one per record, and that one read the old project.
  def move_to_requested_project
    target_id = params.dig(:time_session, :project_id).to_s.presence
    return if target_id.nil? || target_id == @time_session.project_id

    @time_session.project = Project.find_by(id: target_id)
    policy = TimeSessionPolicy.new(current_user, @time_session)
    return if @time_session.project && policy.update?

    raise Pundit::NotAuthorizedError.new(query: :update?, record: @time_session, policy: policy)
  end

  # Resolves one subject id (ticket_id/meeting_id) from the form against the
  # booking's project. Absent key → leave untouched; blank → clear; unknown id → clear + log.
  def assign_subject_from_params(kind, scope)
    key = "#{kind}_id"
    return unless params[:time_session].key?(key)

    id = params[:time_session][key]
    if id.blank?
      @time_session.public_send("#{key}=", nil)
      return
    end

    @time_session.public_send("#{kind}=", scope.find(id))
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error "Could not find #{kind} with ID #{id} in project #{@time_session.project_id}"
    @time_session.public_send("#{key}=", nil)
  end

  # Every booking the viewer may see here, WITHOUT the page's filters and without
  # the smart folder. Read by the list as its starting point and by ListRows as
  # the denominator of "x von y ausgeblendet" -- which is why it must inherit
  # neither: inside a smart folder, "von 13:40" has to keep meaning "of this
  # subject in this month", not "of this folder".
  #
  # @project is nil on the index (the list is the organisation's; a project is
  # project_id_filter). It is set on the write actions, so the list frame
  # re-rendered after a create narrows to the project just booked in.
  def visible_time_sessions_scope
    @visible_time_sessions_scope ||= begin
      base = @project.present? ? @project.time_sessions : TimeSession.where(organisation_id: current_organisation.id)
      policy_scope(base)
    end
  end

  # The viewing rule for this organisation, for the pill and the project filter.
  # Read once for those two; policy_scope (the rows, Pundit's door) and the
  # navigation service still build their own from the same rows. Folding all
  # of them onto one object is a separate cut (review of PR #675, finding 2).
  def organisation_viewing_scope
    @organisation_viewing_scope ||= TimeSessions::ViewingScope.for_organisation(
      user: current_user, organisation: current_organisation
    )
  end

  # "Nothing booked yet" for THIS reader, judged by the visible set and not by
  # what exists: a bare exists? on the model told a can_view_own user whether
  # the colleagues book here. The index hides the filter chrome on it and the
  # list picks the first-use explainer.
  def time_sessions_first_use?
    return @time_sessions_first_use if defined?(@time_sessions_first_use)

    @time_sessions_first_use = !visible_time_sessions_scope.exists?
  end
  helper_method :time_sessions_first_use?

  # The projects this person may book time in (TimeSessionNavigationService:
  # can_create_own, admins everywhere). The record button and the form's
  # project select read it; before, the button was always there and the form
  # listed every project of the organisation.
  def bookable_projects
    @bookable_projects ||= navigation_service.bookable_projects
  end
  helper_method :bookable_projects

  def can_book_time?
    return @can_book_time if defined?(@can_book_time)

    @can_book_time = bookable_projects.exists?
  end
  helper_method :can_book_time?

  def navigation_service
    @navigation_service ||= TimeSessionNavigationService.new(current_user, current_organisation)
  end

  # May this person see the status table of booked time per project? Gates the
  # view switch in the title box and the overview view itself.
  def time_overview_available?
    return @time_overview_available if defined?(@time_overview_available)

    @time_overview_available = TimeSessionStatisticsPolicy.new(current_user, current_organisation).index?
  end
  helper_method :time_overview_available?

  def overview_view?
    params[:view] == 'overview' && time_overview_available?
  end

  # Whether this list can show anybody else's time at all. A filter that cannot
  # change the result is not a filter, and offering it to someone who may only
  # see their own hours promises something the rights do not allow. With a
  # project filter the question is that project's tier; without one, anywhere.
  def shows_foreign_time?
    return @shows_foreign_time if defined?(@shows_foreign_time)

    filtered_project_id = params[:project_id_filter].presence
    @shows_foreign_time = if filtered_project_id
                            organisation_viewing_scope.tier_for(filtered_project_id) == :all
                          else
                            organisation_viewing_scope.sees_others?
                          end
  end
  helper_method :shows_foreign_time?

  # ONE page of rows, plus the bookings under them. Both callers of the list go
  # through here.
  def load_row_page(filtered_query)
    # Both queries start from the IDS, never from the filtered relation itself.
    # On the search path it carries .distinct and joins (TimeSessionFilterService,
    # find_time_sessions): a GROUP BY over that is a Postgres error, and a .sum
    # over it is SUM(DISTINCT), which swallows two equal durations into one.
    rows_base = TimeSession.where(id: filtered_query.reorder(nil).select(:id))
    keys_relation = row_keys_relation(rows_base)

    pagy_instance, page = paginate(keys_relation, items: rows_per_page, count: row_count(keys_relation))
    page_keys = page.pluck(*row_key_columns)

    sessions = TimeSessions::ListRows.narrow_to(rows_base, page_keys)
                                     .preload(*ROW_INCLUDES)
                                     .select('time_sessions.*', "#{TimeSessions::ListRows.month_key_sql} AS month_key")
                                     .to_a

    months = TimeSessions::ListRows.call(
      visible_scope: visible_time_sessions_scope, sessions: sessions, page_keys: page_keys
    )

    [months, pagy_instance, sessions]
  end

  # The rows of the list, in the order the page shows them: months newest first,
  # inside a month alphabetically by subject, "ohne Bezug" last.
  #
  # The tail (project, ticket, meeting) is not decoration. Two rows with the same
  # title in the same month would otherwise share every sort value, and Postgres
  # is then free to order them differently for LIMIT/OFFSET on page 1 than on
  # page 2 -- one row twice, another one never.
  def row_keys_relation(rows_base)
    rows_base.left_joins(:ticket, :meeting, :project)
             .group(:project_id, :ticket_id, :meeting_id, month_key_column,
                    Arel.sql('tickets.title'), Arel.sql('meetings.title'), Arel.sql('projects.name'))
             .order(month_key_column.desc,
                    Arel.sql(SUBJECTLESS_SQL),
                    Arel.sql(SUBJECT_TITLE_SQL),
                    :project_id, :ticket_id, :meeting_id)
  end

  # Pagy would call .count(:all) on the grouped relation itself, which returns a
  # Hash of every group: the whole result set loaded into memory to learn its
  # size. Counting the subquery asks the database for the number instead.
  def row_count(keys_relation)
    TimeSession.unscoped.from(keys_relation.unscope(:order).select(*row_key_columns), :rows).count
  end

  def row_key_columns
    [:project_id, :ticket_id, :meeting_id, month_key_column]
  end

  def month_key_column
    Arel.sql(TimeSessions::ListRows.month_key_sql)
  end

  def rows_per_page
    [items_per_page, MAX_ROWS_PER_PAGE].min
  end

  def find_time_sessions
    # The BASE, not yet narrowed by anything the reader can switch off. The
    # subject filter used to be applied here as well as in
    # TimeSessionFilterService, one rule with two enforcers -- and the copy here
    # sat below every filter, so dropping ticket_id from the service's
    # attributes left the list filtered by it anyway. That is precisely what the
    # empty state's drop-one probe does, so the duplicate had to go. The service
    # applies exactly the same condition (#apply_ticket_filter); the way from a
    # ticket to its hours is covered over HTTP in
    # spec/requests/organisations/time_sessions_ticket_drilldown_spec.rb.
    #
    # No sorting, no eager loading, no DISTINCT: this is the FILTER, and
    # #load_row_page reduces it to its ids anyway. The rows are ordered in
    # #row_keys_relation and their bookings are preloaded in the second query.
    visible_time_sessions_scope
  end

  # The empty state's diagnosis, plus the records whose NAMES it prints.
  #
  # The three are looked up through their own rule and not through the
  # collections the filter selects are built from: those are narrowed by the
  # other filters (the billing picker follows the status filter and the project),
  # so the very filter that emptied the list can be the one keeping its own name
  # out of the list it was chosen from. A junk id casts to NULL on a uuid column
  # and finds nothing, which is the fallback label.
  #
  # The project's rule is the viewing scope, the same owner as the project
  # select: "may this reader see time there". ProjectPolicy::Scope asks about
  # the other areas instead, and answered a reader whose only right is a
  # TimeSessionPermission with the bare word "Projekt" for the project they had
  # just picked by name (Zweitreview of S3). The ticket stays behind the tickets
  # area on purpose: the subject select is gated by that area too, so a title
  # the pill prints is a title the reader could have chosen there.
  # Who the four id filters actually point at. Each through its own door, and
  # the doors differ on purpose:
  #   project        -- the viewing scope, the same owner the project pill lists
  #                     from ("may this reader see time there"). ProjectPolicy
  #                     ::Scope asks about the other areas and answered a reader
  #                     whose only right is a TimeSessionPermission with the bare
  #                     word "Projekt" for the project they had just picked.
  #   ticket/meeting -- their own areas, so a title a pill prints is a title the
  #                     reader could have reached there anyway.
  #   person         -- among the people the menu offers (filtered_person).
  #   tag            -- among the tags the menu offers (filtered_tag).
  #   billing        -- a billing holding a booking the reader may see. One query
  #                     with a subquery, where the policy scope would pluck two
  #                     unbounded id lists for the same answer.
  #
  # Guarded on presence: find_by(id: nil) is still a round trip, and three of
  # these are unset on almost every render.
  def load_filter_selection
    @filtered_project = organisation_viewing_scope.projects.find_by(id: params[:project_id_filter]) if params[:project_id_filter].present?
    @filter_ticket_statuses = load_filter_ticket_statuses
    @filtered_ticket_status = TimeSessions::TicketStatusValues.find(@filter_ticket_statuses, params[:ticket_status])
    @filtered_ticket = policy_scope(Ticket).find_by(id: params[:ticket_id]) if params[:ticket_id].present?
    @filtered_meeting = policy_scope(Meeting).find_by(id: params[:meeting_id]) if params[:meeting_id].present?
    @filtered_person = filtered_person
    @filtered_tag = filtered_tag
    return if params[:time_session_group_id].blank?

    @filtered_group = TimeSessionGroup.where(id: visible_time_sessions_scope.select(:time_session_group_id))
                                      .find_by(id: params[:time_session_group_id])
  end

  # Who a typed creator_id names, looked up ONLY among the people the menu
  # offers (D5 of doc/zeiten_weitere_filter_plan.md). An id outside them (a
  # colleague in a project the reader cannot see, junk) names nobody, so the
  # page never prints a name the list itself would not show. The reader's own
  # id is the switch "Nur meine Zeiten", not a person (D4).
  def filtered_person
    creator_id = TimeSessions::ListFilters.normalize_id(params[:creator_id])
    return if creator_id.blank? || creator_id == current_user.id

    @filter_people.find { |person| person.id == creator_id }
  end

  # Everyone who booked time the reader may see (D2), across the organisation
  # and across every period: narrowed by the period, a person would vanish from
  # the menu the moment a month is picked. Never the member list: a member whose
  # time the reader cannot see must not be named on this page.
  def load_filter_people
    User.where(id: visible_time_sessions_scope.select(:creator_id)).order(:first_name, :last_name, :id).to_a
  end

  # The status values of the chosen project, for the ticket filter (step 3b of
  # doc/zeiten_weitere_filter_plan.md). Only while a project is chosen, and only
  # when the reader sees a booking there on a ticket they may open: the same
  # condition that offers the phase (E5), narrowed to this project. Without it a
  # value would be a statement about tickets the reader cannot open, and every
  # value would answer with an empty list anyway.
  def load_filter_ticket_statuses
    return [] unless @filtered_project

    on_readable_ticket = visible_time_sessions_scope.where(project_id: @filtered_project.id,
                                                           ticket_id: policy_scope(Ticket).select(:id))
    return [] unless on_readable_ticket.exists?

    TimeSessions::TicketStatusValues.for(@filtered_project)
  end

  # The tag behind a typed tag_id, looked up only among the tags the menu
  # offers, for the same reason as the person (D5): an id outside them names
  # nothing. The list still filters by it and finds nothing.
  def filtered_tag
    tag_id = TimeSessions::ListFilters.normalize_id(params[:tag_id])
    return if tag_id.blank?

    @filter_tags.find { |tag| tag.id == tag_id }
  end

  # The tags that could find something here (step 2 of
  # doc/zeiten_weitere_filter_plan.md): on a booking the reader may see, or on
  # the ticket of one. Like the people, across every period and project. A tag
  # used only on notes, or only where the reader sees no time, would be a
  # choice that always answers with an empty list.
  #
  # ⚠️ The taggings are narrowed to this organisation's tags INSIDE the
  # subquery. Tagging has no tenant scope, and the organisation condition on
  # the outer Tag query did not stop Postgres from reading every tagging of
  # every organisation first (EXPLAIN ANALYZE in the review of step 2: 533,000
  # taggings, about 40 ms per list render, 3 to 7 ms with the narrowing). The
  # narrowing matches the leading tag_id of the taggings indexes.
  def load_filter_tags
    visible = visible_time_sessions_scope
    organisation_taggings = Tagging.where(tag_id: Tag.where(organisation_id: current_organisation.id).select(:id))
    tag_ids = organisation_taggings.where(taggable_type: TimeSession.name, taggable_id: visible.select(:id))
                                   .or(organisation_taggings.where(taggable_type: Ticket.name,
                                                                   taggable_id: visible.select(:ticket_id)))
                                   .select(:tag_id)
    Tag.where(id: tag_ids).order(:name, :id).to_a
  end

  # Everything the filter labels and the filter COUNT are computed from, in one
  # hash. Built here rather than in each view because four surfaces read it --
  # the filter line, the reset link, the mobile badge and the empty state -- and
  # a helper may not reach for @ivars (Rails/HelperInstanceVariable).
  def build_filter_state
    {
      date_range: @effective_date_range,
      start_date: @effective_start_date,
      end_date: @effective_end_date,
      project: @filtered_project,
      ticket: @filtered_ticket,
      meeting: @filtered_meeting,
      group: @filtered_group,
      status_filters: @effective_status_filters,
      # A smart folder narrows the list as hard as anything with a pill, and it
      # is the one filter with no control of its own -- which makes the reset the
      # only way out of it.
      smart_folder: @active_smart_folder,
      creator_id: TimeSessions::ListFilters.normalize_id(params[:creator_id]),
      # "Nur meine Zeiten" is true of the reader's OWN id only; creator_id is a
      # typeable parameter and the assistant's report links here with a
      # colleague's id, which is a different filter with a different name.
      creator_mine: TimeSessions::ListFilters.normalize_id(params[:creator_id]) == current_user.id,
      # The person behind a colleague's id, when the reader may see their time.
      person: @filtered_person,
      tag: @filtered_tag,
      # The raw value says whether the filter is in force (an unknown phase
      # empties the list); the phase is the valid key the pill can name.
      ticket_phase: params[:ticket_phase],
      phase: (params[:ticket_phase] if TimeSessions::TicketPhase.valid?(params[:ticket_phase])),
      # The same pair for a concrete value (step 3b): the raw one for the
      # count, the offered choice for the pill (D5: an unoffered value names
      # nothing).
      ticket_status: params[:ticket_status],
      ticket_status_choice: @filtered_ticket_status,
      search: params[:search]
    }
  end

  def authorize_creator!
    return if @time_session.creator == current_user
    return if current_user.account_admin_in?(@current_organisation)

    flash[:alert] = t('flash.time_sessions.no_edit_permission')
    redirect_to organisation_project_time_session_path(@current_organisation, @project, @time_session)
  end

  # Tri-state group contract for the actor (plan D-T3-3): absent key = no group
  # change, blank value = explicit removal, id = assignment. The group is
  # resolved HERE so a foreign/unknown id stays a tenant-scoped 404 (T1
  # pattern); the actor re-checks its billed state inside the transaction.
  def group_change_from_params
    raw = params[:time_session]
    return { requested: false, group: nil } unless raw&.key?(:time_session_group_id)

    id = raw[:time_session_group_id]
    # Raw params are needed for the absent-key check, but only a scalar String
    # is a usable id — an Array/Hash value would reach find as-is (NoMethodError
    # in the actor). Non-strings degrade to nil = blank value (main parity:
    # permit dropped the non-scalar key and the removal path ran).
    id = nil unless id.is_a?(String)
    { requested: true, group: id.present? ? TimeSessionGroup.find(id) : nil }
  end

  # Maps a failed actor Result onto the record for the form re-render (T1
  # popover pattern: coded domain errors pass through, unexpected failures get
  # a generic localized fallback; validation errors already sit on the record
  # from save!).
  def apply_save_failure(result)
    case result.code
    when :validation_failed
      nil
    when :group_billed, :session_billed
      result.errors.each { |message| @time_session.errors.add(:base, message) }
    else
      @time_session.errors.add(:base, t('services.save_time_session.generic_error'))
    end
  end

  # Single source of the post-update redirect (before: the same cascade was
  # computed twice per request, the first result discarded).
  def redirect_path_after_update
    if params[:context] != 'index_page' && @time_session.ticket.present?
      organisation_project_ticket_path(@current_organisation, @project, @time_session.ticket)
    else
      helpers.time_list_path(@current_organisation, project: @project)
    end
  end

  def build_time_session
    # The billing group is deliberately NOT assigned here — the actor owns the
    # group transition (billed guard) via group_change_from_params.
    creation_params = time_session_params.except(:time_session_group_id)
    if @project.present?
      time_session = @project.time_sessions.build(creation_params)
    else
      # For organisation-wide view, create with project from params
      time_session = TimeSession.new(creation_params)
      if params[:time_session][:project_id].present?
        project = Project.find(params[:time_session][:project_id])
        time_session.project = project
      end
    end
    time_session.creator = current_user
    time_session.organisation = current_organisation
    time_session.ticket = @ticket if time_session.ticket_id.blank? && @ticket.present?
    # Deliberate duplication of the ticket fallback above (its twin). A subject can
    # arrive via context (@meeting) instead of the form; both ids must be blank so
    # context never sets a second subject. Two subject types only — if a third ever
    # appears, decide then whether to unify.
    time_session.meeting = @meeting if time_session.ticket_id.blank? && time_session.meeting_id.blank? && @meeting.present?
    time_session
  end

  def ensure_valid_occurred_on
    return unless params[:time_session][:occurred_on].present?

    begin
      parsed_date = Date.parse(params[:time_session][:occurred_on])
    rescue StandardError
      parsed_date = Date.current
    end

    # Store at midnight of the entered date IN THE APP ZONE. `Date#to_time` builds
    # the time in the SERVER's system zone, so on a non-UTC host the value lands on
    # the previous day in UTC (e.g. 22:00) — which shifts dates and the "this week"
    # window by a day. `in_time_zone` is deterministic and matches the API path
    # (Api::V1::TimeSessionsController#parsed_occurred_on uses Time.zone.parse).
    @time_session.occurred_on = parsed_date.in_time_zone
  end

  def redirect_after_success(status: :found)
    if @time_session.ticket.present?
      redirect_to organisation_project_ticket_path(@current_organisation, @project, @time_session.ticket),
                  notice: t('flash.time_sessions.created'), status: status
    elsif @time_session.meeting.present?
      redirect_to organisation_project_meetings_path(@current_organisation, @project, meeting_id: @time_session.meeting_id),
                  notice: t('flash.time_sessions.created'), status: status
    else
      redirect_to helpers.time_list_path(@current_organisation, project: @project),
                  notice: t('flash.time_sessions.created'), status: status
    end
  end

  # Re-renders the list frame after a create with context=index_page. It goes
  # through the SAME row builder as #index: two builders is how the list ends up
  # in one shape on load and another after saving. It still knows nothing about
  # the page's filters, which is a separate defect (TODO), not a new one.
  def load_time_sessions_for_index
    @list_months, @pagy, @time_sessions = load_row_page(visible_time_sessions_scope)
  end

  # Everything the capture popover renders, for #subject_popover AND for the
  # create response with context=subject_popover (success re-renders it fresh,
  # failure re-renders it around the errored record in @popover_time_session).
  # All numbers and rows go through the reader's ViewingScope — the same
  # narrowing the chip's sum uses (SubjectTimeSummaryService), so the popover
  # can never show a session its own sum does not count.
  def load_subject_popover_data
    @popover_subject ||= @ticket || @meeting
    viewing = TimeSessions::ViewingScope.call(user: current_user, project: @project)
    visible = viewing.apply(@popover_subject.time_sessions)
    @popover_scope = viewing.tier
    @popover_buckets = TimeSessions::BucketTotals.call(scope: visible)
    @popover_sessions = visible.includes(:time_session_group)
                               .order(occurred_on: :desc, created_at: :desc)
                               .limit(POPOVER_SESSIONS_LIMIT)
    @popover_can_write = policy(@project).area_access?(:time_sessions, :write)
    return if @popover_time_session.present?

    @popover_time_session = @project.time_sessions.build(
      ticket: (@popover_subject if @popover_subject.is_a?(Ticket)),
      meeting: (@popover_subject if @popover_subject.is_a?(Meeting))
    )
  end

  # The projects the filter offers: the ones in which the reader sees any time.
  def load_accessible_projects
    navigation_service.accessible_projects_with_time_sessions
  end

  # Only billings that hold at least one booking the reader may see. The
  # visible set goes in as a subquery, not as a list of every visible id.
  def load_accessible_time_session_groups
    TimeSessionGroup.joins(:time_sessions)
                    .where(time_sessions: { id: visible_time_sessions_scope.select(:id) })
                    .distinct
                    .ordered
  end

  # The subjects a reader can actually filter by: the ones that HAVE booked time
  # in the list they are allowed to see. Twin of the method above and through
  # the same door, for the same reason -- an option that can only answer with an
  # empty list is not an option.
  #
  # ⚠️ Across ALL projects, not just a chosen one (D4). Until S6 a meeting could
  # not be filtered at all and a ticket only inside its project, so the control
  # had to wait for a project to be picked and the filter row jumped the moment
  # it appeared. Both ids are real filters now
  # (TimeSession::SUBJECT_FILTER_PARAMS), so the pill keeps its place and
  # carries the project name with it -- which is also the only way to tell two
  # meetings of the same name apart, the case S6 exists for.
  #
  # Gated the way the single lookups above are (policy_scope, see
  # load_filtered_records): a session may be visible while its subject sits in
  # an area the reader has no door to, and a filter must not become a way of
  # reading titles out of one.
  # Returns [subjects, capped], the way #load_row_page returns its triple: the
  # menu needs to say that it is showing a window, and "did we cut anything" is
  # not readable off the array afterwards (exactly MAX subjects and more than
  # MAX both arrive as MAX).
  def load_filter_subjects
    visible = filter_subject_source

    # Ranked ACROSS both columns before anything is cut. Taking the top N of
    # each separately would give a ticket a place a more recent meeting had
    # earned, and the reader sees one menu, not two.
    #
    # ⚠️ The cut happens HERE, on recency, and never again. The display sort
    # below is by project and title, and cutting after it would quietly turn the
    # budget back into an alphabetical one -- which is what the first version of
    # this did, and the recency example caught it.
    ranked = SUBJECT_ID_COLUMNS.flat_map do |column|
      recent_subject_ids(visible, column).map { |id, last_booked| [column, id, last_booked] }
    end
    ranked = ranked.sort_by { |(_, _, last_booked)| last_booked }.reverse.first(MAX_FILTER_SUBJECTS + 1)

    capped = ranked.size > MAX_FILTER_SUBJECTS
    ranked = ranked.first(MAX_FILTER_SUBJECTS)
    ids = SUBJECT_ID_COLUMNS.index_with do |column|
      ranked.filter_map { |(ranked_column, id, _)| id if ranked_column == column }
    end

    # ⚠️ project: :organisation, not just :project. The label goes through
    # TimeSessionsHelper#time_session_subject_presentation, which builds a route
    # out of project.organisation -- so :project alone bought one organisations
    # query per distinct project, per subject type. ROW_INCLUDES in the same
    # helper already preloads the same chain for the same reason.
    # (Found in review of #693.)
    tickets = policy_scope(Ticket).where(id: ids[:ticket_id]).includes(project: :organisation)
    meetings = policy_scope(Meeting).where(id: ids[:meeting_id]).includes(project: :organisation)

    subjects = (tickets.to_a + meetings.to_a).sort_by { |subject| [subject.project&.name.to_s, subject.title.to_s] }

    # The chosen subject is pinned in, whatever the cap says. The cap is by
    # RECENCY and the choice is the reader's; a booking picked last spring would
    # otherwise fall out of its own pill's menu, and the one option a menu must
    # always contain is the one it is currently showing.
    chosen = @filtered_ticket || @filtered_meeting
    subjects.unshift(chosen) if chosen.present? && subjects.none? { |subject| subject == chosen }

    [subjects, capped]
  end

  # The bookings the subject menu is built from. Narrowed to a chosen project,
  # the way the billing options have always been (see "Additionally filter by
  # project" in #index) -- the two pills sit side by side and answered to
  # different rules, and the one that ignored the project was also the unbounded
  # one. D4 is untouched: with NO project chosen the menu still reaches across
  # all of them, which is the case S6 exists for.
  def filter_subject_source
    active_project_id = params[:project_id_filter].presence
    return visible_time_sessions_scope if active_project_id.blank?

    visible_time_sessions_scope.where(project_id: active_project_id)
  end

  # The MAX+1 most recently booked subjects of one column, as [id, last_booked].
  # Ordered by the last booking rather than by title: "what did I work on
  # lately" is the question a filter menu answers, and an alphabetical cut would
  # drop a subject for the accident of its name. One grouped read per column,
  # each on an index that starts with it
  # (index_time_sessions_on_ticket_occurred, index_time_sessions_on_meeting_id).
  #
  # MAX+1, so the caller can tell "exactly the budget" from "more than it".
  def recent_subject_ids(scope, column)
    scope.where.not(column => nil)
         .group(column)
         .reorder(Arel.sql('MAX(occurred_on) DESC'))
         .limit(MAX_FILTER_SUBJECTS + 1)
         .pluck(column, Arel.sql('MAX(occurred_on)'))
  end

  # The list's door, the same one the menu entry uses.
  def authorize_time_session_access
    return if navigation_service.can_show_all_time_sessions_menu?

    flash[:alert] = t('flash.time_sessions.no_overview_permission')
    redirect_to organisation_root_path(organisation_id: current_organisation.id)
  end
end
