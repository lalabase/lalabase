# frozen_string_literal: true

class Organisations::KnowledgeController < Organisations::BaseController
  include Pageable
  include AdHocFilterable
  include ViewportSwitchable
  include ProjectController

  skip_before_action :authorize_project_access!
  before_action :authorize_knowledge_access
  before_action :set_viewport_mode, only: [:index]

  setup_pagination 10

  def index
    authorize @project, :index?, policy_class: KnowledgePolicy

    @type = params[:type].presence || Knowledge::TypeRegistry::ALL_TYPE
    @type = Knowledge::TypeRegistry::ALL_TYPE unless valid_type?(@type)

    load_smart_folders
    set_active_view

    # Search mode for the FilterBar (URL parameter as the single source of truth)
    @current_search_mode = params[:search_mode].presence || 'content'

    # An edited dissolvable view is applied as effective ad-hoc filters and the
    # folder's rules step aside (AdHocFilterable, S3a). The folder itself stays
    # with the query: it still narrows the knowledge types to its target and
    # supplies the default sort, neither of which the dissolver expresses.
    # A built-in type view (S7) narrows the types the same way, unless the
    # reader edited it: then the type condition of the effective set does.
    result = KnowledgeSearchQuery.new(
      @project,
      params,
      {
        current_user: current_user,
        accessible_type_keys: accessible_type_keys,
        active_smart_folder: @active_smart_folder,
        apply_folder_query: !edited_saved_view?,
        builtin_type: edited_saved_view? ? nil : @type,
        filter_params: list_filter_params,
        operator_params: list_filter_op_params,
        per_page: items_per_page
      }
    ).call
    @pagy = result.pagy
    @knowledge_items = result.items

    set_selected_item
    set_new_type

    # HTML only, on purpose. The list refresh (filter bar, pagination) works through the
    # `knowledge_results` Turbo frame and page visits, nothing asks this action for a
    # turbo_stream. A stream branch here was worse than useless: notes#create and
    # documents#create redirect into this action, fetch follows the 302 with Turbo's
    # submit Accept header (turbo-stream first), Rails picked the stream branch and
    # Turbo rendered the stream INSTEAD of visiting the page, so the create form stayed
    # in the frame and every further "Speichern" created a duplicate.
    # `formats: [:html]` pins that even for a client that accepts turbo-stream only.
    # Guard: spec/requests/organisations/knowledge_create_via_turbo_submit_spec.rb
    render :index, formats: [:html]
  end

  private

  def authorize_knowledge_access
    return if accessible_type_keys.any?

    flash[:alert] = t('flash.shared.not_authorized')
    redirect_to organisation_project_path(@current_organisation, @project)
  end

  # Readable knowledge types of the user (registry keys), determines the UNION arms
  # and the type pills in the FilterBar.
  def accessible_type_keys
    @accessible_type_keys ||= Knowledge::TypeRegistry.keys.select do |key|
      policy(@project).area_access?(Knowledge::TypeRegistry.fetch(key)[:access_area], :read)
    end
  end

  def can_access_notes?
    accessible_type_keys.include?('note')
  end

  def can_access_documents?
    accessible_type_keys.include?('document')
  end

  def can_write_notes?
    @can_write_notes ||= policy(@project).area_access?(:notes, :write)
  end

  def can_write_documents?
    @can_write_documents ||= policy(@project).area_access?(:documents, :write)
  end

  helper_method :can_access_notes?, :can_access_documents?, :can_write_notes?, :can_write_documents?,
                :accessible_type_keys

  def valid_type?(type)
    type == Knowledge::TypeRegistry::ALL_TYPE || Knowledge::TypeRegistry.key?(type)
  end

  # ── Smart Folders ──

  def load_smart_folders
    @knowledge_smart_folders = policy_scope(SmartFolder)
                               .where(target_object_type: knowledge_smart_folder_targets)
                               .order(:name)

    return if @project.blank?

    @knowledge_smart_folders = @knowledge_smart_folders
                               .where('project_id IS NULL OR project_id = ?', @project.id)
  end

  def knowledge_smart_folder_targets
    accessible_type_keys.filter_map { |key| Knowledge::TypeRegistry.saved_view_target(key) } + ['All']
  end

  # Resolve active views through the same readable, project-scoped list as the tabs.
  def active_folder_record
    return @active_folder_record if defined?(@active_folder_record)

    @active_folder_record = @knowledge_smart_folders.find_by(id: params[:smart_folder_id]) if params[:smart_folder_id].present?
  end

  # The active folder or built-in type view is exposed as @dissolver_result.
  def set_active_view
    @active_smart_folder = active_folder_record
    @dissolver_result = dissolved_active_view if @active_smart_folder || builtin_view_result
  end

  # The type views live in code (doc/filterleiste_s5_s8_plan.md, D1): each is
  # a dissolvable view with exactly one condition, Typ: <key>, so the whole
  # machinery of the bar (dirty state, save row, undo, the effective set on
  # the server) works on it unchanged. Only a type the reader may read is one
  # (a ?type= they may not read keeps the list empty under the base tab, as
  # before the bar), and only where more than one type is readable: with a
  # single type the base view is that type already, and the tabs are not
  # rendered either (KnowledgeFilterHelper#knowledge_builtin_views).
  def builtin_view_result
    return @builtin_view_result if defined?(@builtin_view_result)

    key = params[:type].to_s
    @builtin_view_result =
      if params[:smart_folder_id].blank? && Knowledge::TypeRegistry.key?(key) &&
         accessible_type_keys.include?(key) && accessible_type_keys.size > 1
        SmartFolderDissolver::Result.new(dissolvable: true, ad_hoc_filters: { 'type' => [key] },
                                         ad_hoc_operators: {}, complex_rules: [])
      end
  end

  # ── The new form as a state of the address ──

  # ?new=note|document renders the new form in the lane (S2 of
  # doc/wissen_als_bahn_plan.md): the phone has no frame to load a form into,
  # so its "+" leaves the page and notes#new / documents#new send it back here
  # with this parameter; a deep link can carry it too. Only a type the reader
  # may write, and never beside an open entry.
  def set_new_type
    @new_type = nil
    return if @selected_item.present?

    type = params[:new].presence
    return unless type && Knowledge::TypeRegistry.key?(type)
    return unless policy(@project).area_access?(Knowledge::TypeRegistry.fetch(type)[:access_area], :write)

    @new_type = type
    @note = Note.new if type == 'note'
    # With its first version built, as documents#new does: fields_for
    # :document_versions renders nothing for a document without one, and the
    # page state (the phone's "+", a deep link) showed a form with no fields.
    @document = Document.new.tap { |document| document.document_versions.build } if type == 'document'
  end

  # ── Selected Item ──

  def set_selected_item
    @selected_item = nil

    accessible_type_keys.each do |key|
      entry = Knowledge::TypeRegistry.fetch(key)
      item_id = params[entry[:param_key]]
      next if item_id.blank?

      @selected_item = entry[:model_name].constantize.where(project_id: @project.id).find_by(id: item_id)
      break if @selected_item
    end

    set_preview_version
  end

  # ?preview=VERSION_ID, the sub-state of an open document (doc/dateivorschau_plan.md,
  # D1): one of ITS versions in the lane. A preview that names no version of the
  # selected document is ignored and the document renders, so a stale parameter
  # carried to another row cannot show a foreign file.
  def set_preview_version
    @preview_version = nil
    return unless @selected_item.is_a?(Document)

    version_id = params[KnowledgeFilterHelper::PREVIEW_PARAM].presence
    @preview_version = @selected_item.document_versions.find_by(id: version_id) if version_id
  end
end
