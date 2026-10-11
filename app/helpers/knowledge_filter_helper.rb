# frozen_string_literal: true

# Filter categories for the Knowledge list (PE-C of the knowledge filter
# rebuild: tag, creator, created_at, updated_at). Pools span all type arms
# the user can access (type_keys from Knowledge::TypeRegistry).
# Shares operator and date-preset conventions with AdHocFilterHelper.
module KnowledgeFilterHelper
  I18N_SCOPE = 'views.organisations.knowledge.index'

  # @param project [Project]
  # @param type_keys [Array<String>] accessible registry keys, e.g. %w[note document]
  # @return [String] JSON array of category objects for the FilterBar
  def knowledge_filter_categories_json(project, type_keys)
    date_preset_options = SmartFolders::DatePresets::KEYS.map do |preset|
      { value: preset, label: t("#{I18N_SCOPE}.date_preset_#{preset}") }
    end

    type_category = if type_keys.size > 1
                      [{
                        key: 'type',
                        label: t("#{I18N_SCOPE}.filter_type_label"),
                        icon: 'bi-collection',
                        type: 'special',
                        allowed_operators: %w[or],
                        options: type_keys.map { |key| { value: key, label: t(Knowledge::TypeRegistry.fetch(key)[:label_key]) } }
                      }]
                    else
                      []
                    end

    (type_category + [
      {
        key: 'tag',
        label: t("#{I18N_SCOPE}.filter_tag"),
        icon: 'bi-tag',
        type: 'special',
        allowed_operators: AdHocFilterHelper::OPERATOR_MAP['tag'],
        options: knowledge_tag_options(project, type_keys),
        empty_hint: t("#{I18N_SCOPE}.no_tag_options")
      },
      {
        key: 'creator',
        label: t("#{I18N_SCOPE}.filter_creator"),
        icon: 'bi-person-badge',
        type: 'special',
        allowed_operators: AdHocFilterHelper::OPERATOR_MAP['creator'],
        options: knowledge_creator_options(project, type_keys)
      },
      {
        key: 'created_at',
        label: t("#{I18N_SCOPE}.filter_created_at"),
        icon: 'bi-calendar-plus',
        type: 'special',
        allowed_operators: AdHocFilterHelper::OPERATOR_MAP['date'],
        options: date_preset_options
      },
      {
        key: 'updated_at',
        label: t("#{I18N_SCOPE}.filter_updated_at"),
        icon: 'bi-calendar-check',
        type: 'special',
        allowed_operators: AdHocFilterHelper::OPERATOR_MAP['date'],
        options: date_preset_options
      }
    ]).to_json
  end

  # The built-in views of the knowledge list (doc/filterleiste_s5_s8_plan.md,
  # S7, D1: in code): one per readable type, each a fixed tab carrying exactly
  # the condition Typ: <key>. The type category above is the same condition
  # made by hand; both meet in KnowledgeSearchQuery. None with a single
  # readable type, like the category: the base view is that type already, and
  # a tab that changes nothing is a control without a function (D4). The
  # address of a tab is the component's (NeoFilterBarComponent#view_url).
  def knowledge_builtin_views(current_type, type_keys)
    return [] unless type_keys.size > 1

    type_keys.map do |key|
      { key: key, name: t(Knowledge::TypeRegistry.fetch(key)[:label_key]), active: current_type == key }
    end
  end

  # The selection parameters of the knowledge page, in registry order: the
  # types a row opens into the lane. One owner for the three places that list them: the
  # page wrapper's layout-toggle and index-page values, and every row's
  # list-row params value (S2 of doc/wissen_als_bahn_plan.md). They exclude
  # each other: the opener deletes the others before it sets its own.
  def knowledge_selection_params
    Knowledge::TypeRegistry.keys.map { |key| Knowledge::TypeRegistry.fetch(key)[:param_key] }
  end

  # The sub-state of an open document: ?preview=VERSION_ID shows one version in
  # the lane (doc/dateivorschau_plan.md, D1). Goes wherever the selection goes.
  PREVIEW_PARAM = 'preview'

  # The page's three parameter groups (D9), for the wrapper's data-lane-params.
  def knowledge_lane_params_json
    lane_params_json(selection: knowledge_selection_params, preview: [PREVIEW_PARAM], form: ['new'])
  end

  # What a way back to the list drops: the selection, its preview, a form state.
  def knowledge_lane_state_params
    knowledge_selection_params + [PREVIEW_PARAM, 'new']
  end

  # The restorer's road to a preview state (data-lane-preview-url): the
  # preview route with LaneHelper's placeholders where the document and the
  # version go.
  def knowledge_preview_url_template(organisation, project)
    preview_organisation_project_document_path(organisation_id: organisation.id, project_id: project.id,
                                               id: LaneHelper::SELECTION_PLACEHOLDER, version_id: LaneHelper::PREVIEW_PLACEHOLDER)
  end

  # target_object_type a saved view gets for a type condition with exactly one
  # value; a type without saved views has none.
  def knowledge_type_targets
    Knowledge::TypeRegistry.keys.to_h do |key|
      target = Knowledge::TypeRegistry.saved_view_target(key)
      [key, SmartFolder::SUPPORTED_OBJECT_TYPES.key?(target) ? target : nil]
    end
  end

  # target_object_type -> badge icon for mixed smart folder pills (PE-B)
  def knowledge_type_badge_icons
    Knowledge::TypeRegistry.keys.to_h do |key|
      entry = Knowledge::TypeRegistry.fetch(key)
      [entry[:model_name], entry[:icon]]
    end
  end

  private

  # Tags that are used on any visible knowledge item of the given types.
  def knowledge_tag_options(project, type_keys)
    tag_names = type_keys.flat_map do |key|
      entry = Knowledge::TypeRegistry.fetch(key)
      item_ids = entry[:base_scope].call(project)
      Tag.joins(:taggings)
         .where(taggings: { taggable_type: entry[:model_name],
                            taggable_id: item_ids.select("#{item_ids.table_name}.id") })
         .where(organisation_id: ActsAsTenant.current_tenant&.id)
         .distinct.pluck(:name)
    end

    tag_names.uniq.sort.map { |name| { value: name, label: name } }
  end

  # Users who can read any of the given knowledge areas (creator filter pool).
  def knowledge_creator_options(project, type_keys)
    users = type_keys.flat_map do |key|
      project.users_with_access(:read, Knowledge::TypeRegistry.fetch(key)[:access_area]).to_a
    end

    users.uniq.map { |u| { value: u.id, label: u.display_name } }
         .sort_by { |o| o[:label].downcase }
  end
end
