# frozen_string_literal: true

require 'csv'

class Organisations::TimeSessionGroupsController < Organisations::BaseController
  include Pageable

  # A Pundit denial on #entries must answer INSIDE the frame. The shared handler
  # redirects, and a redirect to a page without that frame leaves the reader
  # looking at "Wird geladen ..." for ever: the panel offers every open billing,
  # but seeing into one needs rights, so the denial is a normal outcome here.
  # Every other action keeps the shared behaviour.
  rescue_from Pundit::NotAuthorizedError do
    next user_not_authorized unless action_name == 'entries'

    render partial: 'organisations/time_session_groups/entries_denied',
           locals: { group: @time_session_group }, layout: false, status: :forbidden
  end

  before_action :authenticate_user!
  before_action :set_time_session_group, only: %i[show edit update destroy entries chronological aggregated customer_export billing_status update_billing_status generate_customer_descriptions update_customer_description export_customer_descriptions]
  before_action :authorize_time_session_group, only: %i[show edit update destroy entries chronological aggregated customer_export generate_customer_descriptions update_customer_description export_customer_descriptions]
  before_action :load_time_sessions, only: %i[show entries chronological aggregated customer_export]

  def index
    authorize TimeSessionGroup
    resolve_billing_states
    resolve_billing_period

    base = policy_scope(TimeSessionGroup)
    filters = {
      project_id: params[:project_id],
      start_date: @effective_start_date&.to_s,
      end_date: @effective_end_date&.to_s,
      search: params[:search]
    }

    filtered = TimeSessionGroupFilterService.new(
      # :organisation rides along because the row policies ask
      # record.organisation per row (update?/destroy?); without the preload that
      # is one association query per row. Guarded by the index example in
      # time_session_groups_query_count_spec.
      base_query: base.ordered.includes(:organisation),
      billing_status: @current_billing_status,
      **filters
    ).call

    @pagy, @time_session_groups = paginate(filtered)
    load_group_aggregates(@time_session_groups)
    load_filter_figures(base, filters, filtered)

    @accessible_projects = load_accessible_projects
  end

  def show
    # Redirect to chronological view as default
    redirect_to chronological_organisation_time_session_group_path(@current_organisation, @time_session_group)
  end

  # What this billing already holds, as a fragment for the assignment panel's
  # lazy turbo-frame. Read-only.
  #
  # It rides on the SAME before_actions as every other view of a billing, which
  # is the whole point of putting it here rather than in the time-sessions
  # controller: authorize runs, and load_time_sessions policy_scopes the rows. A
  # panel that showed a billing's contents unscoped would hand somebody who may
  # only see their own hours a list of everybody's.
  def entries
    render partial: 'organisations/time_session_groups/entries',
           locals: { group: @time_session_group, time_sessions: @time_sessions },
           layout: false
  end

  def chronological
    render :chronological
  end

  def aggregated
    # :ticket_number — a billing document reads in invoice order, not alphabetically.
    @sessions_by_subject = TimeSession.group_by_subject(@time_sessions, order: :ticket_number)
    render :aggregated
  end

  def customer_export
    @sessions_with_description = @time_sessions.where.not(customer_description: nil).count
    render :customer_export
  end

  def new
    @time_session_group = TimeSessionGroup.new
    authorize @time_session_group
  end

  def create
    @time_session_group = TimeSessionGroup.new(time_session_group_params)
    @time_session_group.organisation = current_organisation
    @time_session_group.creator = current_user
    authorize @time_session_group

    if @time_session_group.save
      redirect_to organisation_time_session_groups_path(@current_organisation),
                  notice: t('flash.time_session_groups.created')
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    result = Actors::UpdateTimeSessionGroupBilling.call(
      group: @time_session_group, params: time_session_group_params, current_user: current_user
    )

    if result.success?
      flash[:notice] = t('flash.time_session_groups.updated')
      respond_to do |format|
        # From the modal the page around the form is stale after a save (name
        # headline, list row) - the honest answer is a refresh, the
        # TimeSessionsController precedent.
        format.turbo_stream { render turbo_stream: turbo_stream.refresh }
        format.html { redirect_to organisation_time_session_groups_path(@current_organisation) }
      end
    else
      map_actor_errors(result)
      render :edit, status: :unprocessable_content
    end
  end

  # The billing-status modal's form (D4 of
  # doc/abrechnung_detail_angleichung_plan.md). Rendered bare: the modal frame
  # extracts its matching turbo-frame, and the form is all there is.
  def billing_status
    authorize @time_session_group, :mark_as_billed?
    render :billing_status, layout: false
  end

  # The billing transition, split out of #update (user decision 02.09.): one
  # route = one policy line = one params list. mark_as_billed? is stricter
  # than update? on purpose - the status is Admin/Finance business (Q3,
  # approved), while renaming stays with the creator. The actor underneath is
  # the same; an absent :billed key over there means "no billing change", so
  # the split cannot be re-merged by a stray parameter.
  def update_billing_status
    authorize @time_session_group, :mark_as_billed?

    result = Actors::UpdateTimeSessionGroupBilling.call(
      group: @time_session_group, params: billing_status_params, current_user: current_user
    )

    if result.success?
      flash[:notice] = t('flash.time_session_groups.updated')
      respond_to do |format|
        # The whole page reads differently after a transition (head figures,
        # primary action, invoice column) - refresh, not per-region streams.
        format.turbo_stream { render turbo_stream: turbo_stream.refresh }
        format.html do
          redirect_to organisation_time_session_group_path(@current_organisation, @time_session_group)
        end
      end
    else
      map_actor_errors(result)
      render :billing_status, layout: false, status: :unprocessable_content
    end
  end

  def destroy
    @time_session_group.destroy
    redirect_to organisation_time_session_groups_path(@current_organisation),
                notice: t('flash.time_session_groups.deleted')
  end

  # Generate customer descriptions for all time sessions in the group
  def generate_customer_descriptions
    authorize @time_session_group, :generate_customer_descriptions?

    actor = Actors::GenerateGroupCustomerDescriptions.new(
      group: @time_session_group, regenerate: params[:regenerate] == 'true', current_user: current_user
    )
    result = actor.call

    if result.success?
      notice = if actor.outcome.mode == :enqueued
                 t('flash.time_session_groups.descriptions_background')
               else
                 build_flash_message(actor.outcome.results)
               end
      redirect_to organisation_time_session_group_path(@current_organisation, @time_session_group),
                  notice: notice
    else
      redirect_to organisation_time_session_group_path(@current_organisation, @time_session_group),
                  alert: generate_error_message(result)
    end
  end

  # Update a single customer description (for inline editing)
  def update_customer_description
    authorize @time_session_group, :generate_customer_descriptions?

    time_session_id = params[:time_session_id]
    new_description = params[:customer_description]

    time_session = @time_session_group.time_sessions.find(time_session_id)

    if time_session.update(customer_description: new_description)
      render json: {
        success: true,
        message: t('flash.time_session_groups.customer_description_updated'),
        customer_description: new_description
      }
    else
      render json: {
        success: false,
        message: t('flash.time_session_groups.customer_description_update_failed'),
        errors: time_session.errors.full_messages
      }, status: :unprocessable_entity
    end
  rescue StandardError => e
    Rails.logger.error("Failed to update customer description: #{e.message}")
    render json: {
      success: false,
      message: t('flash.time_session_groups.customer_description_update_error')
    }, status: :internal_server_error
  end

  # Export customer descriptions to CSV (Excel-compatible)
  def export_customer_descriptions
    authorize @time_session_group, :export_customer_descriptions?

    time_sessions = policy_scope(@time_session_group.time_sessions)
                    .includes(:project, :ticket, :meeting, :creator)
                    .order(occurred_on: :asc)

    # Generate CSV file. The subject columns are named "Bezug", not "Ticket": a
    # session's subject is a ticket OR a meeting, and while these columns read
    # .ticket only, meeting-booked time reached the customer as an unexplained
    # line. Only tickets carry a number, so the number column stays empty for
    # meetings rather than inventing an identifier.
    csv_data = CSV.generate(headers: true, col_sep: ';', encoding: 'UTF-8') do |csv|
      # Header row
      csv << [
        t('views.organisations.time_session_groups.customer_export.csv.date'),
        t('views.organisations.time_session_groups.customer_export.csv.subject_number'),
        t('views.organisations.time_session_groups.customer_export.csv.subject'),
        t('views.organisations.time_session_groups.customer_export.csv.internal_description'),
        t('views.organisations.time_session_groups.customer_export.csv.customer_description'),
        t('views.organisations.time_session_groups.customer_export.csv.duration')
      ]

      # Data rows
      time_sessions.each do |ts|
        subject = ts.subject
        csv << [
          ts.occurred_on&.strftime('%d.%m.%Y'),
          subject.is_a?(Ticket) ? subject.number : nil,
          subject&.title,
          ts.description,
          ts.customer_description,
          ts.duration_string
        ]
      end
    end

    # Send file with BOM for Excel compatibility
    filename = "kundenbeschreibungen_#{@time_session_group.name.parameterize}_#{Date.current.strftime('%Y%m%d')}.csv"
    send_data "\xEF\xBB\xBF" + csv_data,
              filename: filename,
              type: 'text/csv; charset=utf-8',
              disposition: 'attachment'
  rescue StandardError => e
    Rails.logger.error("Failed to export customer descriptions: #{e.message}")
    redirect_to organisation_time_session_group_path(@current_organisation, @time_session_group),
                alert: t('flash.time_session_groups.export_error')
  end

  private

  def set_time_session_group
    @time_session_group = TimeSessionGroup.find(params[:id])
  end

  def authorize_time_session_group
    authorize @time_session_group
  end

  # Name and description only (D4): the billing transition has its own
  # endpoint and params list - a :billed key in here would silently re-merge
  # the two forms the split separated.
  def time_session_group_params
    params.require(:time_session_group).permit(:name, :description)
  end

  def billing_status_params
    params.require(:time_session_group).permit(:billed, :invoice_number, :billed_at)
  end

  # RecordInvalid leaves the errors on the same in-memory instance; map the
  # result defensively for other failures. :internal_error carries the raw
  # exception text (e.g. a RecordNotUnique message with the full SQL) - never
  # render that; use a generic flash instead (parity: generate_error_message).
  def map_actor_errors(result)
    return if @time_session_group.errors.any?

    messages = result.code == :internal_error ? [t('flash.time_session_groups.update_error')] : result.errors
    messages.each { |m| @time_session_group.errors.add(:base, m) }
  end

  # Third member of the deliberate result-code->flash passthrough family
  # (TimeSessionAssignmentsController#assignment_error_message,
  # TimeSessionsController#bulk_assign_error_message): billed code -> actor
  # message, generic fallback otherwise. The "unify at the third case" trigger
  # is hereby reached — extract a shared helper when any of the three next
  # changes substantially.
  def generate_error_message(result)
    case result.code
    # Both carry an explanation the generic copy would throw away: WHY this group
    # cannot be generated (already invoiced) resp. WHY the feature is unavailable
    # for this org (R3 — pinned provider, missing credential or no opt-in, each
    # with its own copy). A refusal the user cannot act on is worse than no button
    # at all.
    when :group_billed, :feature_unavailable then result.errors.first
    else t('flash.time_session_groups.descriptions_error')
    end
  end

  # Build flash message from generation results
  #
  # TODO(T2-backlog, plan F2): results[:errors] is ignored here, so batch-level
  # refusals (e.g. the AI-disabled hint from generate_all) surface as a
  # "no descriptions created" NOTICE instead of their actual message. Pending
  # user approval (user-facing delta).
  #
  # @param results [Hash] Results from BulkCustomerDescriptionGenerator
  # @return [String] Human-readable flash message
  def build_flash_message(results)
    messages = []
    messages << t('flash.time_session_groups.descriptions_created', count: results[:success]) if results[:success] > 0
    messages << t('flash.time_session_groups.descriptions_failed', count: results[:failed]) if results[:failed] > 0
    messages << t('flash.time_session_groups.descriptions_skipped', count: results[:skipped]) if results[:skipped] > 0
    return messages.join(', ') if messages.any?

    # 0/0/0 with a recorded error means the generator refused up front (e.g. the
    # feature gate lost a race with a config change) — surface ITS localized
    # sentence instead of the generic nothing-happened line, so the reason the
    # R3 gates now produce is never thrown away (adversarial review R3-B3).
    results[:errors]&.first.presence || t('flash.time_session_groups.no_descriptions_created')
  end

  # The status row's set (billing_states[], user decision 02.09.), with the
  # legacy single-value billing_status still understood: links and bookmarks
  # carry it, and an unknown value still becomes "all" instead of travelling
  # on. The derived single value feeds the filter service and the surfaces
  # that ask "narrowed?" - the service's vocabulary did not change.
  def resolve_billing_states
    states = TimeSessionGroupsHelper::BILLING_STATES
    @effective_billing_states =
      if params.key?(:billing_states)
        raw = Array(params[:billing_states]).select { |value| states.include?(value) }
        raw.presence&.uniq || states.dup
      else
        case params[:billing_status]
        when 'unbilled' then ['unbilled']
        when 'billed' then ['billed']
        else states.dup
        end
      end

    @current_billing_status =
      @effective_billing_states.sort == states.sort ? 'all' : @effective_billing_states.first
  end

  # The period of the billings list (decision D-B of
  # doc/abrechnungen_filterzeile_und_tabelle_plan.md): it filters the billing's
  # own created_at -- the "erstellt" column the list shows -- not the member
  # sessions' occurred_on. Presets come from the shared owner
  # (TimeSessions::ListPeriod) in its TABLE vocabulary: default 'all', because
  # a billings list is short and a monthly default would hide most of it.
  # Hand-typed bounds win over a preset key, and junk becomes "no bound"
  # (TimeSessions::DateBound) instead of a 500.
  def resolve_billing_period
    custom_dates_set = params[:start_date].present? || params[:end_date].present?
    @effective_date_range = if custom_dates_set
                              TimeSessions::ListPeriod::CUSTOM
                            else
                              TimeSessions::ListPeriod.normalize_for_table(params[:date_range])
                            end

    if @effective_date_range == TimeSessions::ListPeriod::CUSTOM
      @effective_start_date = TimeSessions::DateBound.call(value: params[:start_date])
      @effective_end_date   = TimeSessions::DateBound.call(value: params[:end_date])
    else
      @effective_start_date, @effective_end_date = TimeSessions::ListPeriod.bounds_for(@effective_date_range)
    end
  end

  # The figures of the filter line (P2 of the billings plan): what each status
  # option and each project option would answer, counted UNDER THE OTHER
  # FILTERS (the time list's F4 rule: any count must count under the other
  # filters, or picking the option contradicts the number that advertised it),
  # and through the policy scope. Plus the totals the result summary states.
  # A fixed number of queries however long the list; the query-count guard
  # holds it.
  def load_filter_figures(base, filters, filtered)
    except_status = TimeSessionGroupFilterService.new(base_query: base, **filters).call
    grouped = TimeSessionGroup.where(id: except_status.select('time_session_groups.id'))
                              .group(:billed).count
    @billing_status_counts = {
      'unbilled' => grouped[false].to_i,
      'billed' => grouped[true].to_i
    }

    except_project = TimeSessionGroupFilterService.new(
      base_query: base, billing_status: @current_billing_status, **filters.except(:project_id)
    ).call
    except_project_ids = except_project.select('time_session_groups.id')
    @billing_project_counts = policy_scope(TimeSession)
                              .where(time_session_group_id: except_project_ids)
                              .distinct.group(:project_id).count(:time_session_group_id)
    @billing_projects_total = TimeSessionGroup.where(id: except_project_ids).count

    # The result summary's pair. The count is the pagy count: a row IS a
    # billing here, unlike the time list where a row is a subject-month.
    @total_filtered_count = @pagy.count
    # reorder(nil): the filtered relation carries the list's ORDER BY, and a
    # DISTINCT subquery with an ORDER BY column outside its select list is a
    # PG::InvalidColumnReference, not a slow query.
    @total_filtered_duration = policy_scope(TimeSession)
                               .where(time_session_group_id: filtered.reorder(nil).select('time_session_groups.id'))
                               .sum(:duration)
  end

  # Count and minutes per billing in ONE grouped query each, policy-scoped: the
  # figures mean "what you can see in there" (same rule as
  # TimeSessionsHelper#unbilled_time_session_group_minutes). The view used to
  # ask per row -- two queries per billing. Guarded by
  # time_session_groups_query_count_spec.
  def load_group_aggregates(groups)
    scoped = policy_scope(TimeSession).where(time_session_group_id: groups.map(&:id))
    @group_session_counts = scoped.group(:time_session_group_id).count
    @group_session_minutes = scoped.group(:time_session_group_id).sum(:duration)
    # The project names under each row's name (P3), in ONE query for the page:
    # TimeSessionGroup#projects is a per-record query and would be the same
    # N+1 the two lines above replace. Sorted so "which name comes first" is
    # stable and not the database's mood.
    @group_project_names = scoped.joins(:project)
                                 .distinct.pluck(:time_session_group_id, 'projects.name')
                                 .group_by(&:first)
                                 .transform_values { |rows| rows.map(&:last).sort }
  end

  # Load accessible projects for filter dropdown
  def load_accessible_projects
    navigation_service = TimeSessionNavigationService.new(current_user, current_organisation)
    navigation_service.accessible_projects_with_time_sessions
  end

  # Load time sessions for display views. Both subject types are eager-loaded
  # together with their own project, because the "Bezug" cell builds a link from
  # subject.project — loading only the session's project leaves that an N+1.
  def load_time_sessions
    @time_sessions = policy_scope(@time_session_group.time_sessions)
                     .includes(:project, :creator, ticket: :project, meeting: :project)
                     .order(occurred_on: :desc, created_at: :desc)
    # The entries fragment renders only the rows. The link-access map and the
    # activity feed belong to the billing's full pages; a lazy panel expansion
    # must not pay a project_permissions query for a map it never reads.
    return if action_name == 'entries'

    # The head's key-figure line (D1 of doc/abrechnung_detail_angleichung_plan.md):
    # one pass over the loaded rows instead of a query per figure. The rows are
    # rendered below anyway, so materialising them here costs nothing extra; the
    # query-count guard over the three views keeps it honest.
    sessions = @time_sessions.to_a
    @group_figures = {
      minutes: sessions.sum { |ts| ts.duration.to_i },
      count: sessions.size,
      date_range: sessions.filter_map(&:occurred_on).minmax,
      project_names: sessions.map { |ts| ts.project.name }.uniq.sort
    }

    @subject_link_access = build_subject_link_access(@time_sessions)
    @activities = @time_session_group.activities
                                     .includes(:actor)
                                     .recent
                                     .limit(20)
  end

  # Answers "may this viewer follow the link to that subject?" once per
  # (project, area) instead of once per row.
  #
  # Pundit caches the policy INSTANCE, but every #area_access? call on it builds a
  # fresh AccessCheck::ProjectAccessService, whose #initialize runs a
  # project_permissions query. Asking inside the row partial therefore cost one
  # query per row — a billing with 100 sessions paid 100 of them. The answer is
  # identical for every row of the same project, so it is computed here and passed
  # into the cell. Guarded by time_session_groups_query_count_spec.
  #
  # The area comes from time_session_subject_presentation, not from a local
  # Ticket/Meeting branch: that helper stays the single place that knows which
  # permission area gates which subject type.
  def build_subject_link_access(time_sessions)
    time_sessions.filter_map(&:subject).each_with_object({}) do |subject, access|
      area = helpers.time_session_subject_presentation(subject).read_area
      key = [subject.project_id, area]
      next if access.key?(key)

      access[key] = policy(subject.project).area_access?(area, :read)
    end
  end
end
