# frozen_string_literal: true

# Controller concern for ad-hoc URL-based filtering.
# Provides filter application, param extraction, and metadata for chips.
#
# Include in controllers that use ObjectListController:
#   include AdHocFilterable
#
# The edited view (doc/filterleiste_s1_s4_plan.md, S3a). The filter bar lets
# the reader change the conditions of a saved view; the address then carries
# the view (smart_folder_id) AND the edits (filter[], filter_op[], and
# filter_drop[] for saved categories the reader emptied). Applying the folder
# query and the edits on top of each other would only ever narrow the list:
# an added value changed nothing, a dropped category stayed. So while the
# active view dissolves into conditions, the list applies the EFFECTIVE set
# instead of the folder query: the saved conditions, overridden per category
# by the address, minus the dropped ones. The same rule lives client-side in
# lib/filter_bar/change_set.js; the pills and the list read the address alike.
# A view with rules the dissolver cannot express keeps the folder query, and
# the bar shows those conditions read-only.
module AdHocFilterable
  extend ActiveSupport::Concern

  included do
    helper_method :ad_hoc_filter_active?, :ad_hoc_filter_metadata, :ad_hoc_filter_params,
                  :ad_hoc_filter_op_params, :dropped_filter_categories
  end

  # Apply ad-hoc filters from URL params to a query.
  # @param query [ActiveRecord::Relation]
  # @return [ActiveRecord::Relation]
  def apply_ad_hoc_filters(query)
    return query unless ad_hoc_filter_active?

    ad_hoc_filter_service.apply(query)
  end

  # Are any ad-hoc filters active (on an edited view: any effective condition)?
  def ad_hoc_filter_active?
    list_filter_params.present? && list_filter_params.any? { |_k, v| Array(v).any?(&:present?) }
  end

  # Metadata for rendering filter chips in the view.
  def ad_hoc_filter_metadata
    return {} unless ad_hoc_filter_active?

    ad_hoc_filter_service.active_filters_metadata
  end

  # The address as typed: the reader's edits. This is what the filter bar
  # receives; it derives the effective set itself from these and the view.
  # A param of the wrong shape (filter[]=x, filter_op=or) is no filter, not a 500.
  def ad_hoc_filter_params
    @ad_hoc_filter_params ||= nested_param(:filter)
  end

  # Extract per-category operator params from URL.
  # e.g. { "status" => "not", "tag" => "and" }
  def ad_hoc_filter_op_params
    @ad_hoc_filter_op_params ||= nested_param(:filter_op)
  end

  # Saved categories the reader emptied (filter_drop[]).
  def dropped_filter_categories
    @dropped_filter_categories ||= Array(params[:filter_drop]).map(&:to_s).reject(&:blank?)
  end

  # True while the address carries a dissolvable view AND edits to it. An
  # operator without values is no edit (the bar never writes one), and neither
  # is an address that spells out exactly the saved conditions: only a set that
  # differs from the view moves the list from the folder query to the effective
  # set. The two engines answer alike for the same conditions (the date presets
  # read one table, SmartFolders::DatePresets), so the switch happens only for
  # a real change.
  def edited_saved_view?
    return @edited_saved_view if defined?(@edited_saved_view)

    edits = ad_hoc_filter_params.present? || dropped_filter_categories.any?
    @edited_saved_view = active_saved_view? && edits &&
                         dissolved_active_view&.dissolvable? == true &&
                         effective_differs_from_saved?
  end

  # A saved view is active: a folder, or a view that lives in code
  # (KnowledgeController's type views, doc/filterleiste_s5_s8_plan.md S7).
  # Both reach the bar as a dissolver result.
  def active_saved_view?
    params[:smart_folder_id].present? || builtin_view_result.present?
  end

  # The dissolver result of the active view, once per request. The
  # controllers hand it to the filter bar as @dissolver_result.
  def dissolved_active_view
    return @dissolved_active_view if defined?(@dissolved_active_view)

    folder = active_folder_record
    @dissolved_active_view = folder ? SmartFolderDissolver.new(folder, current_user).call : builtin_view_result
  end

  # The folder the address names, through the policy scope, once per request
  # (a miss is remembered too). Controllers that set @active_smart_folder read
  # it from here so the folder is not loaded twice.
  def active_folder_record
    return @active_folder_record if defined?(@active_folder_record)

    @active_folder_record = params[:smart_folder_id].present? ? policy_scope(SmartFolder).find_by(id: params[:smart_folder_id]) : nil
  end

  # A view that lives in code rather than as a folder: a dissolver result the
  # controller builds. None by default; KnowledgeController answers with the
  # active type view.
  def builtin_view_result
    nil
  end

  # What the list applies: the effective set on an edited view, else the address.
  def list_filter_params
    @list_filter_params ||= edited_saved_view? ? effective_filter_params : ad_hoc_filter_params
  end

  def list_filter_op_params
    @list_filter_op_params ||= edited_saved_view? ? effective_filter_op_params : ad_hoc_filter_op_params
  end

  private

  def effective_filter_params
    saved = (dissolved_active_view.ad_hoc_filters || {}).stringify_keys
    saved.except(*dropped_filter_categories).merge(ad_hoc_filter_params.stringify_keys)
  end

  # A category the address edits carries its operator in the address too; an
  # absent filter_op there means "or", not the saved operator. An operator for
  # a category the address does not edit is ignored, as the bar ignores it.
  def effective_filter_op_params
    saved = (dissolved_active_view.ad_hoc_operators || {}).stringify_keys
    edited = ad_hoc_filter_params.keys.map(&:to_s)
    saved.except(*dropped_filter_categories, *edited).merge(ad_hoc_filter_op_params.stringify_keys.slice(*edited))
  end

  def effective_differs_from_saved?
    saved = dissolved_active_view
    normalised_conditions(saved.ad_hoc_filters, saved.ad_hoc_operators) !=
      normalised_conditions(effective_filter_params, effective_filter_op_params)
  end

  # The comparison rule of lib/filter_bar/change_set.js#normalise: blank values
  # and empty categories drop out, values sort, a missing operator is "or".
  def normalised_conditions(filters, operators)
    filters = (filters || {}).stringify_keys
    operators = (operators || {}).stringify_keys
    filters.keys.sort.each_with_object({}) do |category, out|
      values = Array(filters[category]).map(&:to_s).reject(&:blank?).uniq.sort
      next if values.empty?

      out[category] = [values, operators[category].presence || AdHocFilterService::DEFAULT_OPERATOR]
    end
  end

  def ad_hoc_filter_service
    @ad_hoc_filter_service ||= AdHocFilterService.new(@project, list_filter_params, list_filter_op_params)
  end

  def nested_param(key)
    raw = params[key]
    raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : {}
  end
end
