# frozen_string_literal: true

# Service to apply ad-hoc URL-based filters to list queries (Tickets, Notes,
# Documents). Translates filter params into ActiveRecord conditions.
# Custom attributes (status, priority, etc.) use JSONB containment queries.
# Special fields (assignee, tag, creator, created_at, updated_at, due_date, waiting, blocking)
# use dedicated subqueries.
# Fields the target model does not support (e.g. assignee on Note) are skipped.
#
# Supports per-category logic operators via operator_params:
#   - "or"  (default): match any of the selected values
#   - "and": match all selected values (multiselect/tag only)
#   - "not": exclude selected values
#
# Usage:
#   service = AdHocFilterService.new(project, params[:filter].to_unsafe_h, params[:filter_op]&.to_unsafe_h)
#   filtered_query = service.apply(Ticket.where(project: project))
#   metadata = service.active_filters_metadata
class AdHocFilterService
  # The bar's categories that are not custom attributes. AdHocToSmartFolderService reads this list,
  # and through it SmartFoldersController#sanitized_filter_params: a new category is added here only.
  SPECIAL_FIELDS = %w[assignee tag creator created_at updated_at due_date waiting blocking].freeze
  # project: the organisation-wide meetings list only ("Alle Meetings"). It narrows
  # an already policy-scoped relation, so an id the reader cannot read matches nothing.
  MEETING_FIELDS = %w[participant occurred_at project].freeze
  VALID_OPERATORS = %w[or and not].freeze
  DEFAULT_OPERATOR = 'or'

  # The date presets on created_at/updated_at (today, this_week, ...) and their ranges are
  # SmartFolders::DatePresets: the one table this list query shares with the smart folder rules.

  attr_reader :project, :filter_params, :operator_params

  # @param project [Project] the current project (for loading attribute definitions, users, tags)
  # @param filter_params [Hash] e.g. { "status" => ["Offen"], "assignee" => ["uuid"], "tag" => ["bug"] }
  # @param operator_params [Hash] e.g. { "status" => "not", "tag" => "and" } — per-category logic operator
  def initialize(project, filter_params, operator_params = {})
    @project = project
    @filter_params = filter_params.presence || {}
    @operator_params = operator_params.presence || {}
  end

  # Apply all active filters to the given query (AND between fields, OR within a field).
  # @param query [ActiveRecord::Relation] base ticket query
  # @return [ActiveRecord::Relation]
  def apply(query)
    return query if filter_params.blank?

    klass = query.klass
    filter_params.each do |key, values|
      next if Array(values).reject(&:blank?).empty?
      next unless field_supported?(key, klass)

      query = if SPECIAL_FIELDS.include?(key) || (klass == Meeting && MEETING_FIELDS.include?(key))
                send("apply_#{key}_filter", query)
              else
                apply_custom_attribute_filter(query, key)
              end
    end

    query
  end

  # Returns true if any filters are active.
  def active?
    filter_params.present? && filter_params.any? { |_k, v| Array(v).any?(&:present?) }
  end

  # Returns metadata about active filters for rendering chips.
  # @return [Hash] e.g. { "status" => [{ value: "Offen", label: "Offen" }], "assignee" => [...] }
  def active_filters_metadata
    metadata = {}

    filter_params.each do |key, values|
      values = Array(values).reject(&:blank?)
      next if values.empty?

      metadata[key] = values.map do |value|
        { value: value, label: label_for_value(key, value) }
      end
    end

    metadata
  end

  private

  # A filter field only applies when the target model supports it
  # (assignee/custom attributes are ticket-only; tag needs taggings;
  # creator needs a creator_id column).
  def field_supported?(key, klass)
    case key
    when 'participant', 'occurred_at'
      klass == Meeting || klass.column_names.include?('custom_attributes')
    when 'project'
      klass == Meeting
    when 'assignee', *Tickets::WaitingStateFilter::STATES
      klass == Ticket
    when 'tag'
      klass.reflect_on_association(:taggings).present?
    when 'creator'
      klass.column_names.include?('creator_id')
    when 'created_at', 'updated_at'
      true
    else
      klass.column_names.include?('custom_attributes')
    end
  end

  # Generic JSONB containment filter for custom attributes (select/multiselect).
  # Supports OR (default), AND (multiselect only), and NOT operators.
  def apply_custom_attribute_filter(query, attr_name)
    values = Array(filter_params[attr_name]).reject(&:blank?)
    return query if values.empty?

    op = operator_for(attr_name)
    attr_def = attribute_definition_for(attr_name)
    table_name = query.table_name

    if attr_def&.field_type == 'multiselect'
      # Multiselect: JSONB array containment — each value wrapped in array
      conditions = values.map { |_v| "(#{table_name}.custom_attributes @> ?)" }
      json_values = values.map { |v| { attr_name => [v] }.to_json }
    else
      # Select (default): JSONB key-value containment
      conditions = values.map { |_v| "(#{table_name}.custom_attributes @> ?)" }
      json_values = values.map { |v| { attr_name => v }.to_json }
    end

    case op
    when 'and'
      # AND: all conditions must match
      conditions.each_with_index do |cond, i|
        query = query.where(cond, json_values[i])
      end
      query
    when 'not'
      # NOT: exclude matches, include NULLs
      or_clause = conditions.join(' OR ')
      query.where("NOT (#{or_clause}) OR #{table_name}.custom_attributes IS NULL", *json_values)
    else
      # OR (default): any condition matches
      query.where(conditions.join(' OR '), *json_values)
    end
  end

  # Assignee filter: EXISTS subquery on ticket_assignments.
  # Supports OR (default) and NOT operators.
  def apply_assignee_filter(query)
    user_ids = Array(filter_params['assignee']).reject(&:blank?)
    return query if user_ids.empty?

    op = operator_for('assignee')
    assignments_table = TicketAssignment.arel_table
    tickets_table = Ticket.arel_table

    subquery = assignments_table.project(1)
                                .where(assignments_table[:ticket_id].eq(tickets_table[:id]))
                                .where(assignments_table[:user_id].in(user_ids))
                                .exists

    if op == 'not'
      query.where.not(subquery)
    else
      query.where(subquery)
    end
  end

  # Creator filter: WHERE creator_id IN (...).
  # Supports OR (default) and NOT operators.
  def apply_creator_filter(query)
    user_ids = Array(filter_params['creator']).reject(&:blank?)
    return query if user_ids.empty?

    if operator_for('creator') == 'not'
      query.where.not(creator_id: user_ids)
    else
      query.where(creator_id: user_ids)
    end
  end

  # Tag filter: Subquery on taggings/tags, scoped to the model of the query
  # (taggings.taggable_type = Ticket/Note/Document/...).
  # Supports OR (default), AND, and NOT operators.
  # Tag-IDs are memoized and taggings stay a subselect so that applying the
  # same service to several queries (UNION arms) costs no extra roundtrips.
  def apply_tag_filter(query)
    tag_names = Array(filter_params['tag']).reject(&:blank?)
    return query if tag_names.empty?

    op = operator_for('tag')
    taggable_type = query.klass.base_class.name
    tag_ids = tag_ids_for(tag_names)

    # Unknown tags: nothing can match (OR/AND), nothing is excluded (NOT)
    return query.none if tag_ids.empty? && op != 'not'
    return query if tag_ids.empty?

    taggings = Tagging.where(tag_id: tag_ids, taggable_type: taggable_type)

    case op
    when 'and'
      # AND: record must have ALL selected tags (intersection via aggregation)
      query.where(id: taggings.group(:taggable_id)
                              .having('COUNT(DISTINCT tag_id) = ?', tag_ids.size)
                              .select(:taggable_id))
    when 'not'
      # NOT: exclude records that have any of the selected tags
      query.where.not(id: taggings.select(:taggable_id))
    else
      # OR (default): record has any of the selected tags
      query.where(id: taggings.select(:taggable_id))
    end
  end

  def tag_ids_for(tag_names)
    @tag_ids_cache ||= {}
    @tag_ids_cache[tag_names] ||= Tag.where(
      name: tag_names,
      organisation_id: ActsAsTenant.current_tenant&.id
    ).pluck(:id)
  end

  def apply_participant_filter(query)
    Meetings::ParticipantFilter.call(query, filter_params['participant'], operator: operator_for('participant'))
  end

  def apply_project_filter(query)
    project_ids = Array(filter_params['project']).grep(String).reject(&:blank?)
    return query if project_ids.empty?

    if operator_for('project') == 'not'
      query.where.not(project_id: project_ids)
    else
      query.where(project_id: project_ids)
    end
  end

  def apply_occurred_at_filter(query)
    apply_date_filter(query, :occurred_at)
  end

  # Date filter on created_at. Preset values are translated to date ranges.
  # Multiple presets = OR (union of ranges).
  def apply_created_at_filter(query)
    apply_date_filter(query, :created_at)
  end

  # Date filter on updated_at. Preset values are translated to date ranges.
  # Multiple presets = OR (union of ranges).
  def apply_updated_at_filter(query)
    apply_date_filter(query, :updated_at)
  end

  # Generic date filter: resolves preset strings to date ranges (the same ranges a
  # smart folder rule with the preset as its operator reads, SmartFolders::DatePresets).
  # Supports OR (default) and NOT operators. Built in Arel, so no SQL string is
  # assembled here: the column name comes from the caller, never from the address.
  def apply_date_filter(query, column)
    presets = Array(filter_params[column.to_s]).reject(&:blank?)
    return query if presets.empty?

    ranges = presets.filter_map { |preset| SmartFolders::DatePresets.range(preset) }
    return query if ranges.empty?

    col = query.arel_table[column]
    any_range = ranges.map { |range| col.between(range) }.reduce(:or)

    operator_for(column.to_s) == 'not' ? query.where(any_range.not) : query.where(any_range)
  end

  # Due-date quick-filter. Each selected preset resolves to a ticket relation via
  # Ticket.matching_due_preset — the ONE place each preset's meaning lives (shared with the SmartFolder
  # relative operators, so a preset filters identically on both surfaces). Presets are OR'd as
  # id-subqueries so they compose uniformly, including `overdue`, which is not a plain date range (it
  # also excludes closed tickets). `not` inverts the whole OR.
  def apply_due_date_filter(query)
    presets = Array(filter_params['due_date']).reject(&:blank?) & Ticket::DUE_DATE_PRESET_KEYS
    return query if presets.empty?

    table = query.table_name
    or_clause = presets
                .map { |preset| "#{table}.id IN (#{query.matching_due_preset(preset).select(:id).to_sql})" }
                .join(' OR ')

    operator_for('due_date') == 'not' ? query.where("NOT (#{or_clause})") : query.where(or_clause)
  end

  # The waiting states (Tickets::WaitingStateFilter): one flag value, "ist" keeps the tickets in
  # the state, "ist nicht" the rest of the list. Any other value filters nothing.
  def apply_waiting_filter(query)
    apply_waiting_state_filter(query, 'waiting')
  end

  def apply_blocking_filter(query)
    apply_waiting_state_filter(query, 'blocking')
  end

  def apply_waiting_state_filter(query, state)
    return query unless Array(filter_params[state]).include?(Tickets::WaitingStateFilter::FLAG_VALUE)

    Tickets::WaitingStateFilter.call(scope: query, state: state, present: operator_for(state) != 'not')
  end

  # Resolve a filter value to its display label.
  def label_for_value(key, value)
    case key
    when 'assignee', 'creator'
      User.find_by(id: value)&.display_name || value
    when 'tag'
      value
    when 'created_at', 'updated_at'
      I18n.t("views.organisations.tickets.index.date_preset_#{value}", default: value)
    when 'due_date'
      I18n.t("views.organisations.tickets.index.due_preset_#{value}", default: value)
    when *Tickets::WaitingStateFilter::STATES
      I18n.t("views.organisations.tickets.index.filter_#{key}")
    else
      custom_attribute_label(key, value)
    end
  end

  # Resolve a custom attribute value to its i18n label.
  def custom_attribute_label(attr_name, value)
    attr_def = attribute_definition_for(attr_name)
    return value unless attr_def

    entry = attr_def.allowed_values&.find { |v| v['value'] == value }
    return value unless entry

    locale = I18n.locale.to_s
    entry.dig('labels', locale) || entry['value']
  end

  # Returns the validated operator for a filter key.
  # Falls back to DEFAULT_OPERATOR ('or') for invalid/missing values.
  def operator_for(key)
    op = operator_params[key].to_s.downcase
    VALID_OPERATORS.include?(op) ? op : DEFAULT_OPERATOR
  end

  # Cached lookup of attribute definitions by name.
  # Preloads all active definitions in a single query on first access.
  def attribute_definition_for(attr_name)
    @attr_defs_cache ||= project.ticket_attribute_definitions.active.index_by(&:name)
    @attr_defs_cache[attr_name]
  end
end
