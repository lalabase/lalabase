# frozen_string_literal: true

# Manages CRUD, sharing, cloning and API endpoints for SmartFolders.
# Delegates result fetching to SmartFolderService and ad-hoc filter
# conversion to AdHocToSmartFolderService.
class Organisations::SmartFoldersController < Organisations::BaseController
  include Sortable
  include Pagy::Backend

  setup_sortable SmartFolder, 'smart_folders.updated_at', true

  before_action :authenticate_user!
  before_action :set_current_organisation
  before_action :require_admin!, only: [:index]
  before_action :set_smart_folder, only: %i[show edit update update_from_filters rename columns destroy share perform_share unshare clone]
  after_action :verify_authorized, except: %i[index]
  after_action :verify_policy_scoped, only: :index

  before_action :set_field_options, only: %i[new create edit update]

  def index
    base_scope = policy_scope(SmartFolder).where(organisation_id: @current_organisation.id)

    if params[:project_id].present?
      @project = selectable_projects.find_by(id: params[:project_id])
      base_scope = base_scope.where(project_id: @project.id) if @project
    end

    if params[:search].present?
      search_term = "%#{params[:search]}%"
      base_scope = base_scope.where('smart_folders.name ILIKE ? OR smart_folders.description ILIKE ?', search_term, search_term)
    end

    sort_column = params[:sort].to_s
    sort_direction = params[:direction].to_s.downcase
    sort_column = 'updated_at' unless %w[name created_at updated_at position].include?(sort_column)
    sort_direction = 'desc' unless %w[asc desc].include?(sort_direction)

    @smart_folders = base_scope.order(sort_column => sort_direction)
    @pagy, @smart_folders = pagy(@smart_folders, items: 20)

    respond_to do |format|
      format.html
      format.turbo_stream
      format.json { render json: { smart_folders: @smart_folders, pagination: @pagy } }
    end
  end

  def show
    authorize @smart_folder

    service = SmartFolderService.new(@smart_folder, current_user)
    page = params[:page] || 1
    per_page = params[:per_page] || 25

    begin
      result = service.fetch_results(page: page, per_page: per_page)
      @items = result[:items]
      @results_pagy = Pagy.new(count: result[:total], page: result[:page], items: result[:per_page])
    rescue Pundit::NotAuthorizedError => e
      redirect_to organisation_smart_folders_path(organisation_id: @current_organisation.id), alert: e.message
      return
    rescue StandardError => e
      Rails.logger.error "Error fetching Smart Folder results for #{@smart_folder.id}: #{e.message}\n#{e.backtrace.join("\n")}"
      redirect_to organisation_smart_folders_path(organisation_id: @current_organisation.id), alert: t('flash.smart_folders.results_error')
      return
    end

    respond_to do |format|
      format.html
      format.turbo_stream
      format.json { render json: { smart_folder: @smart_folder.as_json(include: :smart_folder_rule_groups), items: @items, pagination: @results_pagy } }
    end
  end

  def new
    @smart_folder = SmartFolder.new(organisation: @current_organisation)
    @smart_folder.project_id = params[:project_id] if params[:project_id].present? && selectable_projects.exists?(params[:project_id])
    @smart_folder.target_object_type = params[:context_type] if params[:context_type].present? && SmartFolder::SUPPORTED_OBJECT_TYPES.keys.include?(params[:context_type])

    rule_group = @smart_folder.smart_folder_rule_groups.build(position: 1)
    rule_group.smart_folder_rules.build(position: 1)

    authorize @smart_folder

    respond_to do |format|
      format.html { render layout: turbo_frame_request? ? false : 'application' }
      format.turbo_stream
    end
  end

  def create
    @smart_folder = SmartFolder.new
    @smart_folder.user = current_user
    @smart_folder.organisation = @current_organisation

    @smart_folder.attributes = smart_folder_params
    authorize @smart_folder
    selectable_projects(area: :meetings).find(@smart_folder.project_id) if @smart_folder.target_object_type == 'Meeting' && @smart_folder.project_id.present?

    if @smart_folder.save
      respond_to do |format|
        format.html { redirect_to save_success_redirect_path, notice: t('.success') }
        format.turbo_stream do
          flash.now[:notice] = t('.success')
          @modal_redirect_url = save_success_redirect_path
          render :create
        end
        format.json { render json: @smart_folder, status: :created, location: @smart_folder }
      end
    else
      ensure_nested_objects_for_rerender
      respond_to do |format|
        format.html { render :new, status: :unprocessable_entity }
        format.turbo_stream { render :new, status: :unprocessable_entity }
        format.json { render json: @smart_folder.errors, status: :unprocessable_entity }
      end
    end
  end

  def edit
    authorize @smart_folder

    if @smart_folder.smart_folder_rule_groups.empty? && @smart_folder.target_object_type != 'Meeting'
      rule_group = @smart_folder.smart_folder_rule_groups.build(position: 1)
      rule_group.smart_folder_rules.build(position: 1)
    elsif @smart_folder.smart_folder_rule_groups.any? { |rg| rg.smart_folder_rules.empty? }
      @smart_folder.smart_folder_rule_groups.each do |rg|
        rg.smart_folder_rules.build(position: 1) if rg.smart_folder_rules.empty?
      end
    end

    respond_to do |format|
      format.html { render layout: turbo_frame_request? ? false : 'application' }
      format.turbo_stream
    end
  end

  def update
    authorize @smart_folder

    if @smart_folder.with_lock { @smart_folder.update(smart_folder_params) }
      respond_to do |format|
        format.html { redirect_to save_success_redirect_path, notice: t('.success') }
        format.turbo_stream do
          flash.now[:notice] = t('.success')
          @modal_redirect_url = save_success_redirect_path
          render :update
        end
        format.json { render json: @smart_folder, status: :ok }
      end
    else
      ensure_nested_objects_for_rerender
      respond_to do |format|
        format.html { render :edit, status: :unprocessable_entity }
        format.turbo_stream { render :edit, status: :unprocessable_entity }
        format.json { render json: @smart_folder.errors, status: :unprocessable_entity }
      end
    end
  end

  def destroy
    authorize @smart_folder

    project = @smart_folder.project
    @smart_folder.destroy

    # One redirect target for both branches: back to the source tickets list when we
    # came from there, else the folder list (the folder itself no longer exists).
    @modal_redirect_url = if @smart_folder.target_object_type == 'Meeting' && project.nil?
                            organisation_meetings_path(@current_organisation)
                          elsif params[:return_to].in?(%w[tickets meetings knowledge]) && project.present?
                            filter_save_return_path(project.id)
                          else
                            organisation_smart_folders_path(organisation_id: @current_organisation.id)
                          end

    respond_to do |format|
      format.html { redirect_to @modal_redirect_url, notice: t('.success'), status: :see_other }
      # Turbo submits the modal DELETE as a stream request; destroy.turbo_stream.erb
      # closes the #modal frame and navigates. Without a template turbo-rails would
      # answer 204 No Content and the modal would stay open (bug fixed 2026-07-14).
      format.turbo_stream { flash.now[:notice] = t('.success') }
      format.json { head :no_content }
    end
  end

  # Quick-updates an existing SmartFolder's rules from ad-hoc filter params.
  # Called via PATCH from the filter bar "save changes" action. An org-wide
  # folder has no project of its own; the list the bar sits on sends its
  # project_id, which supplies the attribute definitions for the conversion.
  # Only Meeting folders support an empty set as an unfiltered view. Other
  # targets keep the existing guard because their empty rule tree matches nothing.
  def update_from_filters
    authorize @smart_folder, :update?

    project = @smart_folder.project || selectable_projects.find_by(id: params[:project_id])
    filter_params = project ? sanitized_filter_params(project) : {}
    # A type condition (S7) names the folder's target, which is immutable: it
    # cannot become a rule of this folder. Refused loudly rather than sliced
    # away by the sanitizer, or the bar would record the condition as saved.
    # The bar offers "Als neue Ansicht" for that case, where the type becomes
    # the new folder's target.
    if project.nil? || invalid_filter_update?(filter_params) || filter_carries_type_condition?
      error = t('flash.smart_folders.update_from_filters_error', default: 'Fehler beim Speichern des Filters.')
      return respond_to do |format|
        format.json { render json: { success: false, error: error }, status: :unprocessable_content }
        format.html { redirect_back fallback_location: organisation_smart_folders_path(organisation_id: @current_organisation.id), alert: error }
      end
    end

    result = Actors::SaveSmartFolderFromFilters.call(
      smart_folder: @smart_folder,
      project: project,
      current_user: current_user,
      filter_params: filter_params,
      operator_params: sanitized_operator_params,
      name: @smart_folder.name
    )

    if result.success?
      respond_to do |format|
        format.json { render json: { success: true }, status: :ok }
        format.html do
          redirect_to filter_save_return_path(project.id, smart_folder_id: @smart_folder.id), notice: t('flash.smart_folders.updated_from_filters', default: 'Filter wurde gespeichert.')
        end
      end
    else
      respond_to do |format|
        format.json { render json: { success: false, error: result.errors.to_sentence }, status: :unprocessable_entity }
        format.html do
          redirect_back fallback_location: organisation_smart_folders_path(organisation_id: @current_organisation.id),
                        alert: t('flash.smart_folders.update_from_filters_error', default: 'Fehler beim Speichern des Filters.')
        end
      end
    end
  end

  # Called from the filter bar's tab menu (doc/filterleiste_s5_s8_plan.md, S5).
  # Name only, on purpose: the full update action assumes the whole form (rules
  # and all), which a rename must never touch. Answers JSON only; the bar reads
  # success and name. The columns of a view have their own writer since
  # doc/spaltenwahl_plan.md; the form no longer carries them.
  def rename
    authorize @smart_folder, :update?

    name = params[:name].to_s.strip
    if name.present? && @smart_folder.update(name: name)
      render json: { success: true, name: @smart_folder.name }, status: :ok
    else
      error = @smart_folder.errors.full_messages.to_sentence.presence || t('components.filter_bar.rename_failed')
      render json: { success: false, error: error }, status: :unprocessable_content
    end
  end

  # The view's column list, from the filter bar's save row (doc/spaltenwahl_plan.md,
  # S3): cols[] as the picker wrote it into the address. One trivial write, so it
  # stays here (seam rule). A key the reader may not see in this project is
  # refused as a whole (422), not sliced away: the bar would otherwise record a
  # list as saved that the server never stored. An org-wide folder has no project
  # of its own; the list sends its project_id along, as update_from_filters does.
  def columns
    authorize @smart_folder, :update?

    project = @smart_folder.project || selectable_projects.find_by(id: params[:project_id])
    keys, unknown = resolved_column_keys(project)
    refused = project.nil? || keys.nil? || unknown.any?
    return render json: { success: false, error: t('components.column_picker.columns_unknown') }, status: :unprocessable_content if refused

    # The pins belong to the same view, so they go in the same write (see
    # ViewConfigurationsController#columns). Order matters here: the folder
    # keeps both lists in ONE hash, and the pin writer reads the table list.
    @smart_folder.ordered_columns = keys
    @smart_folder.pinned_column_keys = Array(params[:pins]).map(&:to_s).uniq & ViewConfiguration.available_columns_for(project, @smart_folder.column_view_type, user: current_user).pluck(:key) if params.key?(:pins)
    @smart_folder.save!
    render json: { success: true, columns: @smart_folder.ordered_columns }, status: :ok
  end

  # Converts ad-hoc list filters (tickets or knowledge) into a persisted SmartFolder.
  # The saved folder follows the source list's active type filter via
  # params[:target_object_type] (PE-B); params[:return_to] picks the redirect target.
  def create_from_filters
    @smart_folder = SmartFolder.new(organisation: @current_organisation)
    authorize @smart_folder, :create?

    @smart_folder.target_object_type = filter_save_target_object_type
    project = selectable_projects(area: meeting_folder_context? ? :meetings : nil).find(params[:project_id])
    filter_params = sanitized_filter_params(project)

    # A folder without rules matches nothing, for good (SmartFolderQueryBuilder
    # answers [] on empty rule groups). A type condition alone (S7) arrives as
    # an empty set, because the bar turns it into the target, not a rule.
    if filter_params.values.all?(&:blank?) || (meeting_folder_context? && rejected_filter_params?(filter_params))
      redirect_to filter_save_return_path(project.id), alert: t('flash.smart_folders.create_from_filters_error')
      return
    end

    # A new ticket view starts with the reader's base view columns of the project
    # ("Alle Tickets" is the template, plan D6) and stands alone from then on.
    target = filter_save_target_object_type
    view_type = target == 'Meeting' ? 'meetings' : 'tickets'
    base_columns = ViewConfiguration.for_user_project(current_user, project, view_type)
    inherited = base_columns.ordered_columns if target.in?(%w[Ticket All Meeting])
    result = Actors::SaveSmartFolderFromFilters.call(
      project: project,
      current_user: current_user,
      filter_params: filter_params,
      operator_params: sanitized_operator_params,
      name: params[:smart_folder_name],
      sort_column: params[:sort_column],
      sort_direction: params[:sort_direction],
      target_object_type: target,
      columns: inherited,
      pinned_columns: (base_columns.pinned_column_keys if inherited)
    )

    if result.success?
      redirect_to filter_save_return_path(project.id, smart_folder_id: result.resource.id),
                  notice: t('flash.smart_folders.created_from_filters')
    else
      # Too many conditions is the one refusal the reader can fix, so it says so.
      alert = result.code == :rule_tree_too_large ? result.errors.to_sentence : t('flash.smart_folders.create_from_filters_error')
      redirect_to filter_save_return_path(project.id), alert: alert
    end
  end

  def share
    authorize @smart_folder

    @users_for_sharing = shareable_users.order(:email)
    @existing_shares = @smart_folder.smart_folder_shares.includes(:user).order('users.email')

    respond_to do |format|
      format.html
      format.turbo_stream
    end
  end

  def perform_share
    authorize @smart_folder, :share?

    user_ids = params[:share_user_ids]

    unless user_ids.present? && user_ids.is_a?(Array)
      redirect_to share_organisation_smart_folder_path(organisation_id: @current_organisation.id, id: @smart_folder.id),
                  alert: t('flash.smart_folders.share_select_users')
      return
    end

    # Re-scope the submitted ids against the shareable set → tampered ids pointing at
    # users outside the folder's project (or non-admins for org-global folders) are dropped;
    # the actor shares with all of them or none (all-or-nothing).
    actor = Actors::ShareSmartFolder.new(
      smart_folder: @smart_folder,
      users: shareable_users.where(id: user_ids),
      current_user: current_user,
      # Only what the sharer has: edit rights only from someone who may edit.
      can_edit: params[:share_can_edit] == '1' && policy(@smart_folder).update?,
      can_share: params[:share_can_share] == '1'
    )
    result = actor.call

    if result.success?
      redirect_to organisation_smart_folder_path(organisation_id: @current_organisation.id, id: @smart_folder.id),
                  notice: t('flash.smart_folders.share_success', count: actor.count)
    else
      redirect_to share_organisation_smart_folder_path(organisation_id: @current_organisation.id, id: @smart_folder.id),
                  alert: t('flash.smart_folders.share_error')
    end
  end

  # Revokes a single user's share on this folder. A lone scoped destroy_all with no
  # side effects (no activity/fanout/jobs) — trivial per the actor seam rule, so it
  # stays in the controller (unlike #perform_share, which fans out N writes
  # all-or-nothing through an actor). The destroy is scoped to this folder's shares.
  # Anyone may leave a folder shared with them; removing somebody else's share is
  # for the owner (or an admin), not for every user the folder was shared with.
  def unshare
    target = User.find_by(id: params[:user_id])
    authorize @smart_folder, (target == current_user ? :show? : :manage_shares?)

    @smart_folder.unshare_with(target)

    redirect_to share_organisation_smart_folder_path(organisation_id: @current_organisation.id, id: @smart_folder.id),
                notice: t('flash.smart_folders.unshared')
  end

  def clone
    authorize @smart_folder

    result = Actors::CloneSmartFolder.call(
      source: @smart_folder,
      current_user: current_user,
      new_name: params[:new_folder_name].presence
    )

    # The filter bar asks for JSON and goes to the list with the copy active
    # (20a, S3); the folder form still wants its redirect.
    if result.success?
      respond_to do |format|
        format.json { render json: { success: true, id: result.resource.id, name: result.resource.name }, status: :ok }
        format.html do
          redirect_to organisation_smart_folder_path(organisation_id: @current_organisation.id, id: result.resource.id),
                      notice: t('flash.smart_folders.cloned')
        end
      end
    else
      respond_to do |format|
        format.json { render json: { success: false, error: result.errors.to_sentence }, status: :unprocessable_content }
        format.html do
          redirect_to organisation_smart_folder_path(organisation_id: @current_organisation.id, id: @smart_folder.id),
                      alert: t('flash.smart_folders.clone_error', error: result.errors.to_sentence)
        end
      end
    end
  end

  # --- API endpoints for dynamic form fields (used by Stimulus controllers) ---

  def field_operators
    authorize_filter_builder_access
    field = params[:field]

    project = filter_builder_projects.find_by(id: params[:project_id]) if params[:project_id].present?
    config_with_custom = SmartFolderRule.field_config_with_custom_attributes(
      @current_organisation, project, accessible_project_ids: filter_builder_projects.ids
    )
    config = config_with_custom[field]

    if config
      operators = config[:operators].map do |op|
        {
          value: op,
          label: SmartFolderRule.operator_label(field, op)
        }
      end

      response_data = {
        operators: operators,
        valueType: config[:value_type],
        referenceModel: config[:reference_model],
        valueRequired: config[:value_required],
        # The operators of this field that take no value (is_empty, the deadline presets, the
        # date presets): the rule builder reads this list instead of keeping a copy of
        # SmartFolderRule.optional_value_operators.
        valueless: config[:operators] & SmartFolderRule.optional_value_operators,
        tagsAutocomplete: field == 'tag',
        custom: config[:custom] || false
      }

      if config[:custom] && config[:attribute_definition]
        attr_def = config[:attribute_definition]
        if %w[select multiselect].include?(attr_def.field_type)
          allowed_values = attr_def.allowed_values
          response_data[:customOptions] = allowed_values.map do |opt|
            label = opt['labels']&.dig(I18n.locale.to_s) ||
                    opt['labels']&.dig(I18n.default_locale.to_s) ||
                    opt['value']
            { value: opt['value'], label: label }
          end
        end
      end

      render json: response_data
    else
      render json: { error: t('flash.smart_folders.invalid_field', field: field) }, status: :bad_request
    end
  end

  def reference_options
    authorize_filter_builder_access
    field = params[:field]
    search_term = params[:q].to_s.strip
    projects = if meeting_folder_context? && %w[participant creator project].include?(field)
                 selectable_projects(area: :meetings)
               else
                 filter_builder_projects
               end
    project = projects.find_by(id: params[:project_id]) if params[:project_id].present?

    options = helpers.available_reference_options(
      field, @current_organisation, search_term, project: project, accessible_project_ids: projects.ids,
                                                 area: meeting_folder_context? ? :meetings : :tickets
    )

    if options.present? || field == 'participant'
      render json: { options: options }
    else
      render json: { error: t('flash.smart_folders.no_reference_options', field: field) }, status: :bad_request
    end
  end

  private

  def set_smart_folder
    @smart_folder = policy_scope(SmartFolder).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to organisation_smart_folders_path(organisation_id: @current_organisation.id), alert: t('flash.smart_folders.not_found')
  end

  # Users a smart folder may be shared with: those with access to the folder's project
  # (project-scoped folders) or org admins (org-global folders without a project). Excludes
  # the owner and already-shared users. Single source of truth for the #share picker and
  # the IDOR-safe resolution in #perform_share — a tampered share_user_ids cannot reach a
  # user outside this set, and the picker never lists foreign-project identities.
  def shareable_users
    base = if @smart_folder.project
             @smart_folder.project.users_with_access(:read, @smart_folder.target_object_type == 'Meeting' ? :meetings : :tickets)
           else
             organisation_admin_users
           end
    base.where.not(id: @smart_folder.user_id)
        .where.not(id: @smart_folder.shared_users.select(:id))
  end

  def organisation_admin_users
    admin_role_ids = @current_organisation.roles.where(title: Role::ACCOUNT_ADMIN_TITLE).select(:id)
    User.where(id: @current_organisation.memberships.where(role_id: admin_role_ids).select(:user_id))
  end

  def smart_folder_params
    result = params.require(:smart_folder).permit(
      :name, :description, :target_object_type, :project_id,
      :is_public, :public_access_level, :sort_column, :sort_direction,
      :sort_by, :position, :color_code,
      smart_folder_rule_groups_attributes: [
        :id, :name, :position, :_destroy,
        { smart_folder_rules_attributes: %i[
          id field operator value position _destroy
        ] }
      ]
    )

    # Fall back to context_type from the referencing page (e.g. tickets index → "Ticket")
    result[:target_object_type] = params[:context_type] if result[:target_object_type].blank? && params[:context_type].present?
    result[:target_object_type] ||= 'Note'

    # project_id and target_object_type are immutable after creation — rules
    # are scoped to them, changing would silently invalidate existing rules.
    if action_name == 'update'
      result.delete(:project_id)
      result.delete(:target_object_type)
      # The form shows the visibility fields only to those who may change them
      # (SmartFolderPolicy#publish?); a forged value from anybody else is dropped.
      %i[is_public public_access_level].each { |key| result.delete(key) } unless policy(@smart_folder).publish?
    end

    result
  end

  # cols[] from the address, normalised, against what this reader may see in
  # the project (ViewConfiguration.available_columns_for). Answers [keys, unknown],
  # or nil when the request carries no list at all.
  def resolved_column_keys(project)
    return nil if params[:cols].blank? || project.nil?

    keys = ViewConfiguration.normalize_columns(params[:cols], @smart_folder.column_view_type)
    known = ViewConfiguration.available_columns_for(project, @smart_folder.column_view_type, user: current_user).map { |column| column[:key] }
    [keys, keys - known]
  end

  # PE-B: "Save as Smart Folder" adopts the type of the source page
  # (Tickets -> 'Ticket'; Knowledge depending on the type filter 'All'/'Note'/'Document').
  # The bar derives the target from the type condition (S7); anything it did
  # not name falls back to the list the save came from: a folder of all types
  # for knowledge, a ticket folder for tickets.
  def filter_save_target_object_type
    requested = (params[:target_object_type].presence || params[:context_type]).to_s
    return requested if SmartFolder::SUPPORTED_OBJECT_TYPES.keys.include?(requested)

    return 'Meeting' if params[:return_to] == 'meetings'

    params[:return_to] == 'knowledge' ? 'All' : 'Ticket'
  end

  def filter_carries_type_condition?
    raw = params[:filter]
    raw.respond_to?(:key?) && raw.key?(:type) && Array(raw[:type]).any?(&:present?)
  end

  def meeting_return_context
    context = params[:list_context]
    return {} unless context.is_a?(ActionController::Parameters)

    Meetings::ListState.extract(context).merge(context.permit(:meeting_id, :new).to_h)
  end

  # Redirect target after saving the filter: back to the source page.
  def filter_save_return_path(project_id, smart_folder_id: nil)
    shared = {
      organisation_id: @current_organisation.id,
      project_id: project_id,
      smart_folder_id: smart_folder_id
    }.compact

    if params[:return_to] == 'meetings' || @smart_folder&.target_object_type == 'Meeting' && params[:return_to] != 'knowledge'
      organisation_project_meetings_path(**meeting_return_context.except('smart_folder_id', 'filter', 'filter_op', 'filter_drop', 'participant').symbolize_keys.merge(shared))
    elsif params[:return_to] == 'knowledge'
      organisation_project_knowledge_index_path(**shared)
    else
      organisation_project_tickets_path(**shared)
    end
  end

  # Post-save redirect target for the folder form (#create/#update): back to the
  # list the expert filter was opened from (return_to: tickets, notes or
  # knowledge; the filter bar opens it from the tickets AND the knowledge page)
  # when a project context exists (the folder's own project, else
  # params[:project_id]); standalone Meeting views return to their results, other targets to the folder index. One
  # definition for create and update, the HTML redirect AND the Turbo Stream
  # (@modal_redirect_url in the stream templates), so the four cannot drift.
  def save_success_redirect_path
    project_id = @smart_folder.project&.id || params[:project_id]
    unless project_id.present? && %w[notes tickets knowledge meetings].include?(params[:return_to])
      return organisation_smart_folder_path(@current_organisation, @smart_folder) if @smart_folder.target_object_type == 'Meeting'

      return organisation_smart_folders_path(organisation_id: @current_organisation.id)
    end

    case params[:return_to]
    when 'meetings'
      filter_save_return_path(project_id, smart_folder_id: @smart_folder.id)
    when 'notes'
      organisation_project_notes_path(organisation_id: @current_organisation.id, project_id: project_id)
    when 'knowledge'
      organisation_project_knowledge_index_path(organisation_id: @current_organisation.id, project_id: project_id)
    else
      organisation_project_tickets_path(organisation_id: @current_organisation.id, project_id: project_id)
    end
  end

  # Seeds a form row on validation errors; empty Meeting views stay intentionally empty.
  def ensure_nested_objects_for_rerender
    if @smart_folder.smart_folder_rule_groups.empty? && @smart_folder.target_object_type != 'Meeting'
      rule_group = @smart_folder.smart_folder_rule_groups.build(position: 1)
      rule_group.smart_folder_rules.build(position: 1)
    elsif @smart_folder.smart_folder_rule_groups.any? { |rg| rg.smart_folder_rules.empty? }
      @smart_folder.smart_folder_rule_groups.each do |rg|
        rg.smart_folder_rules.build(position: 1) if rg.smart_folder_rules.empty?
      end
    end
  end

  def set_field_options
    @field_options = available_field_options
  end

  def available_field_options
    target_type = @smart_folder&.target_object_type || params[:context_type] || 'All'
    project = @smart_folder&.project || filter_builder_projects.find_by(id: params[:project_id])
    helpers.available_field_options(
      target_type, @current_organisation, project: project, accessible_project_ids: filter_builder_projects.ids
    )
  end

  # Projects whose (ticket) fields may be offered in the filter builder.
  # Custom attributes hang off the project, hence area: :tickets — so a user does not see
  # field names from projects they may not read. The single definition of this
  # scope choice, so that the three filter builder endpoints are guaranteed to use the same one.
  def filter_builder_projects
    selectable_projects(area: :tickets)
  end

  # The filter builder endpoints (field_operators/reference_options) do not load a
  # SmartFolder resource, so verify_authorized does not trigger on its own. We
  # authorize the unbound builder at membership level; actual folder creation also checks its target —
  # the actual confidentiality protection lies in the project scoping of the delivered
  # options, not in the gate of the endpoint.
  def authorize_filter_builder_access
    authorize :smart_folder, :create?
  end

  def set_current_organisation
    @current_organisation = current_organisation
    return if @current_organisation

    redirect_to root_path, alert: t('flash.organisations.not_found')
  end

  def require_admin!
    return if current_user.account_admin_in?(@current_organisation)

    redirect_to root_path, alert: t('shared.errors.not_authorized')
  end

  def meeting_folder_context?
    target = @smart_folder&.persisted? ? @smart_folder.target_object_type : filter_save_target_object_type
    target == 'Meeting'
  end

  # Replacing a rule tree through chips must not silently drop unknown input.
  # Clearing is a deliberate action, separate from missing input. Whether the
  # stored tree may be replaced at all (no expert rules) is checked by
  # Actors::SaveSmartFolderFromFilters under the row lock.
  def invalid_filter_update?(filters)
    empty = filters.values.all?(&:blank?)
    return empty unless @smart_folder.target_object_type == 'Meeting'
    return true if rejected_filter_params?(filters)

    empty && params[:clear_filters] != '1'
  end

  def rejected_filter_params?(filters)
    raw = params[:filter]
    return false if raw.nil?
    return true unless raw.is_a?(ActionController::Parameters)

    raw.keys.any? { |key| !filters.key?(key) }
  end

  def sanitized_filter_params(project)
    raw = params[:filter]
    return {} unless raw.respond_to?(:to_unsafe_h)

    allowed_keys = if meeting_folder_context?
                     %w[participant creator occurred_at created_at updated_at]
                   else
                     AdHocToSmartFolderService::SPECIAL_FIELDS + project.ticket_attribute_definitions.active.pluck(:name)
                   end
    raw.to_unsafe_h.slice(*allowed_keys).transform_values { |v| Array(v).map(&:to_s).reject(&:blank?) }
  end

  def sanitized_operator_params
    raw = params[:filter_op]
    return {} unless raw.respond_to?(:to_unsafe_h)

    raw.to_unsafe_h.each_with_object({}) do |(key, val), result|
      normalized = val.to_s.downcase
      result[key] = normalized if AdHocFilterService::VALID_OPERATORS.include?(normalized)
    end
  end
end
