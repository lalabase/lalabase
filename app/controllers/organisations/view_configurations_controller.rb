# frozen_string_literal: true

class Organisations::ViewConfigurationsController < Organisations::BaseController
  include ProjectController

  skip_before_action :authorize_project_access!
  before_action :authorize_project_show
  before_action :set_view_configuration

  def update
    if @view_configuration.update(view_configuration_params)
      respond_to do |format|
        format.html { redirect_to column_list_path, notice: t('flash.view_configurations.updated') }
        format.json { render json: { success: true, columns: @view_configuration.ordered_columns } }
      end
    else
      respond_to do |format|
        # there is no edit template any more: the one-list modal went with the
        # legacy filter bar. The HTML path is a no-JS fallback now, so it says
        # what went wrong on the page the reader came from.
        format.html do
          redirect_to column_list_path,
                      alert: @view_configuration.errors.full_messages.to_sentence
        end
        format.json { render json: { success: false, error: @view_configuration.errors.full_messages.to_sentence }, status: :unprocessable_content }
      end
    end
  end

  # The picker's "für alle Ansichten übernehmen" (doc/spaltenwahl_plan.md, D5):
  # the list as it stands into the base view and every ticket view of the
  # reader's own in this project. A form post with a page as its answer, so the
  # flash can name the count. A key the reader may not see drops out.
  # The column picker saves into the view it stands on at once (user,
  # 07.09.2026: no asking); this is the base view's endpoint, a folder has its
  # own (SmartFoldersController#columns). Same param (cols[]), same answer. A
  # key the reader may not see is refused as a whole (422), not sliced away.
  def columns
    keys = ViewConfiguration.normalize_columns(params[:cols], column_view_type)
    known = @view_configuration.available_columns.map { |column| column[:key] }
    refused = params[:cols].blank? || (keys - known).any?
    return render json: { success: false, error: t('components.column_picker.columns_unknown') }, status: :unprocessable_content if refused

    # The pins ride along in the same request (designer, 07.09.2026): they are
    # a property of THIS view, like the list and its order, so they are written
    # in the same breath. A request without the param leaves them alone -
    # anything else would clear a reader's pins on the first save from an older
    # tab.
    @view_configuration.ordered_columns = keys
    @view_configuration.pinned_column_keys = pinned_keys_param & known if params.key?(:pins)
    @view_configuration.save!
    render json: { success: true, columns: @view_configuration.ordered_columns }, status: :ok
  end

  # Only keys the reader may see, normalised the same way the list is.
  def pinned_keys_param
    Array(params[:pins]).map(&:to_s).uniq
  end

  def apply_columns_to_all
    keys = ViewConfiguration.normalize_columns(params.dig(:view_configuration, :table_columns), column_view_type)
    known = @view_configuration.available_columns.map { |column| column[:key] }
    actor = Actors::ApplyColumnsToViews.new(project: @project, current_user: current_user, columns: keys & known, view_type: column_view_type)
    result = actor.call

    if result.success?
      redirect_to column_list_path,
                  notice: t('flash.view_configurations.applied_to_all', count: actor.applied_count), status: :see_other
    else
      redirect_to column_list_path,
                  alert: result.errors.to_sentence, status: :see_other
    end
  end

  def update_view_mode
    mode = params[:view_mode]
    @view_configuration.update!(view_mode: mode) if mode && ViewConfiguration::VIEW_MODES.include?(mode)
    # Back to the page the switch was pressed on, with its address: a closed
    # lane sends no ticket_id, an open one does, and the filters travel too
    # (doc/kanban_ticket_als_bahn_plan.md, section 4.7). The Referer is the
    # document's live address, which pushState keeps current; no hidden field,
    # so no stale ticket from render time.
    redirect_back fallback_location: column_list_path,
                  status: :see_other, allow_other_host: false
  end

  private

  def authorize_project_show
    authorize @project, :show?
    head :forbidden unless policy(@project).area_access?(column_view_type.to_sym, :read)
  end

  def column_view_type
    params[:view_type] == 'meetings' ? 'meetings' : 'tickets'
  end

  def column_list_path
    column_view_type == 'meetings' ? organisation_project_meetings_path(@current_organisation, @project) : organisation_project_tickets_path(@current_organisation, @project)
  end

  def set_view_configuration
    @view_configuration = ViewConfiguration.for_user_project(current_user, @project, column_view_type)
    @view_configuration.organisation = @current_organisation
  end

  def view_configuration_params
    permitted = params.require(:view_configuration).permit(
      :view_mode, :kanban_attribute_definition_id,
      table_columns: [],
      header_columns: [],
      detail_settings: [*ViewConfiguration::DETAIL_SETTING_OPTIONS.keys, { custom_field_display: {} }]
    )

    # JSONB columns need plain Hashes — ActionController::Parameters don't serialize correctly
    permitted[:detail_settings] = permitted[:detail_settings].to_unsafe_h if permitted[:detail_settings].respond_to?(:to_unsafe_h)

    # The list goes through its one writer, which also retires the legacy second
    # list (doc/spaltenwahl_plan.md, D1).
    permitted[:ordered_columns] = permitted.delete(:table_columns) if permitted.key?(:table_columns)

    permitted
  end
end
