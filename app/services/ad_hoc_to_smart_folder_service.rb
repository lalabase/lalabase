# frozen_string_literal: true

# Converts ad-hoc filter URL params + operators into a rule-group structure
# (arrays of { field:, operator:, value: } hashes) plus the precomputed field
# config and preloaded references needed to persist them. This is a PURE
# converter — it performs NO persistence. Actors::SaveSmartFolderFromFilters owns
# the write (folder create/update + rule rebuild). `warnings` collects filters
# that have no SmartFolder equivalent (e.g. NOT on a date field).
#
# What this writes, SmartFolderDissolver reads back 1:1 (the round trip of
# doc/filter_datumsvorgaben_rundlauf_plan.md): a date preset is a valueless rule
# operator (SmartFolders::DatePresets), a deadline preset the valueless operator
# of the project's deadline field (Ticket::DUE_DATE_PRESET_KEYS), several values
# of one category are one rule group each (OR).
#
# Usage:
#   conversion = AdHocToSmartFolderService.call(
#     project: project,
#     filter_params: { 'status' => ['Offen'], 'tag' => ['bug', 'urgent'] },
#     operator_params: { 'tag' => 'and' }
#   )
#   conversion.rules_by_group        # => [[{ field:, operator:, value: }, ...], ...]
#   conversion.field_config_map      # => precomputed field config (for the factory)
#   conversion.preloaded_references  # => { 'User' => { id => record } } or nil
#   conversion.warnings              # => ["NOT operator on created_at was skipped..."]
class AdHocToSmartFolderService
  include SmartFolders::Operators

  # The bar's categories that are not custom attributes.
  # SmartFoldersController#sanitized_filter_params lets exactly these through,
  # plus the project's attribute names. The list of AdHocFilterService itself, not
  # a copy: two copies meant every new category had to be added twice, and one
  # forgotten copy dropped the condition silently on save (plan §9, option A).
  SPECIAL_FIELDS = AdHocFilterService::SPECIAL_FIELDS
  MEETING_FIELDS = AdHocFilterService::MEETING_FIELDS

  # The conditions would exceed SmartFolder::MAX_RULE_GROUPS or
  # MAX_RULES_PER_GROUP. Raised before the cross product is built; the message
  # is the one the expert editor shows for the same bound.
  class RuleTreeTooLarge < StandardError; end

  Conversion = Struct.new(:rules_by_group, :field_config_map, :preloaded_references, :warnings, keyword_init: true)

  # project: nil on a list of the whole organisation (a meetings view of
  # "Alle Meetings"); the organisation then has to be named.
  def self.call(project:, filter_params:, operator_params: {}, target_object_type: 'Ticket', organisation: project&.organisation)
    new(project: project, filter_params: filter_params, operator_params: operator_params,
        target_object_type: target_object_type, organisation: organisation).convert
  end

  attr_reader :project, :organisation, :filter_params, :operator_params, :warnings

  def initialize(project:, filter_params:, operator_params: {}, target_object_type: 'Ticket', organisation: project&.organisation)
    @project = project
    @organisation = organisation
    @filter_params = filter_params.presence || {}
    @operator_params = operator_params.presence || {}
    @target_object_type = target_object_type
    @warnings = []
  end

  # Builds the rule-group structure plus everything the persistence actor needs.
  def convert
    rules_by_group = build_rules_for_groups
    Conversion.new(
      rules_by_group: rules_by_group,
      field_config_map: SmartFolderRule.field_config_with_custom_attributes(organisation, project),
      preloaded_references: preload_references(rules_by_group),
      warnings: warnings
    )
  end

  private

  # Determines whether we need multiple rule groups (OR between groups)
  # and builds the rule arrays accordingly.
  #
  # Multi-group is needed when a category has several values in OR (two
  # assignees, "today" or "yesterday"): each value gets its own group, with all
  # other rules duplicated. Otherwise all rules go into a single group (AND
  # within group).
  def build_rules_for_groups
    base_rules = []
    alternatives = {} # field => [rule, ...], one group per rule

    filter_params.each do |key, values|
      # A repeated value is the same condition, not one more alternative.
      values = Array(values).reject(&:blank?).uniq
      next if values.empty?

      converted = convert_filter(key, values)
      if converted.is_a?(Hash) && converted[:or_multi]
        alternatives[converted[:field]] = converted[:rules]
      elsif converted.is_a?(Array)
        base_rules.concat(converted)
      end
    end

    ensure_within_bounds!(base_rules, alternatives)
    return [base_rules].reject(&:empty?) if alternatives.empty?

    # OR over several values of one category = one group per value (groups are
    # OR-combined, base rules are duplicated). With several such categories
    # (assignee AND created_at) the cross product arises: (a1|a2) AND (d1|d2)
    # yields 4 groups — semantically exactly the ad-hoc filter model.
    fields = alternatives.keys
    combos = alternatives[fields.first].product(*fields[1..].map { |f| alternatives[f] })
    combos.map { |combo| base_rules + combo }
  end

  # Counts what build_rules_for_groups would build: one group per combination
  # of alternatives, each holding the base rules plus one rule per category.
  def ensure_within_bounds!(base_rules, alternatives)
    groups = alternatives.values.inject(1) { |count, rules| count * rules.size }
    raise rule_tree_too_large(:too_many_rule_groups, SmartFolder::MAX_RULE_GROUPS) if groups > SmartFolder::MAX_RULE_GROUPS
    return if base_rules.size + alternatives.size <= SmartFolder::MAX_RULES_PER_GROUP

    raise rule_tree_too_large(:too_many_rules, SmartFolder::MAX_RULES_PER_GROUP)
  end

  def rule_tree_too_large(error_key, count)
    RuleTreeTooLarge.new(I18n.t("activerecord.errors.models.smart_folder.#{error_key}", count: count))
  end

  # Convert a single filter key + values into rule attribute hashes.
  # Returns an Array of { field:, operator:, value: } hashes, or the
  # { or_multi: true, field:, rules: } signal for one group per rule.
  def convert_filter(key, values)
    if SPECIAL_FIELDS.include?(key) || (@target_object_type == 'Meeting' && MEETING_FIELDS.include?(key))
      convert_special_filter(key, values)
    else
      convert_custom_attribute_filter(key, values)
    end
  end

  # --- Special field converters ---

  def convert_special_filter(key, values)
    case key
    when 'assignee' then convert_assignee(values)
    when 'tag'      then convert_tag(values)
    when 'creator'  then convert_creator(values)
    when 'project'  then convert_reference('project', values)
    when 'participant' then [{ field: key, operator: { 'and' => HAS_ALL_OF, 'not' => NOT_HAS }.fetch(operator_for(key), HAS_ANY_OF), value: values.to_json }]
    when 'created_at', 'updated_at', 'occurred_at' then convert_date(key, values)
    when 'due_date' then convert_due_date(values)
    when *Tickets::WaitingStateFilter::STATES then convert_waiting_state(key, values)
    else []
    end
  end

  def convert_assignee(values)
    convert_reference('assignee', values)
  end

  def convert_creator(values)
    convert_reference('creator', values)
  end

  # Shared conversion for reference fields (assignee, creator, project):
  # NOT -> not_equals rules in one group; OR with multiple values ->
  # one group per record (alternatives).
  def convert_reference(field, values)
    case operator_for(field)
    when 'not'
      values.map { |id| { field: field, operator: NOT_EQUALS, value: id } }
    else # 'or'
      alternatives(values.map { |id| { field: field, operator: EQUALS, value: id } })
    end
  end

  def convert_tag(values)
    op = operator_for('tag')
    joined = values.join(',')

    case op
    when 'and'
      [{ field: 'tag', operator: HAS_ALL_OF, value: joined }]
    when 'not'
      [{ field: 'tag', operator: NOT_HAS, value: joined }]
    else # 'or'
      [{ field: 'tag', operator: HAS_ANY_OF, value: joined }]
    end
  end

  # A date preset is a valueless operator of the rule (SmartFolders::DatePresets,
  # the one table the bar and the expert filter read): the folder keeps "this
  # week" as this week, and the dissolver reads it back as the preset it was.
  # Several presets are alternatives (OR), never one group (AND).
  def convert_date(key, values)
    return skip_not(key) if operator_for(key) == 'not'

    presets = values.select { |preset| SmartFolders::DatePresets.valid?(preset) }
    alternatives(presets.map { |preset| { field: key, operator: preset, value: nil } })
  end

  # A deadline preset is a valueless operator of the project's deadline field
  # (Ticket::DUE_DATE_PRESET_KEYS, which SmartFolderRule offers on that field
  # only). Without a deadline field the bar never offers the category; the
  # warning covers an address that carries it anyway.
  def convert_due_date(values)
    return skip_not('due_date') if operator_for('due_date') == 'not'

    deadline = TicketAttributeDefinition.deadline_definition_for(project)
    unless deadline
      warnings << I18n.t('services.ad_hoc_to_smart_folder.due_date_without_deadline')
      return []
    end

    presets = values & Ticket::DUE_DATE_PRESET_KEYS
    alternatives(presets.map { |preset| { field: "custom_#{deadline.name}", operator: preset, value: nil } })
  end

  # A waiting state is one flag: "ist" is IS, "ist nicht" IS_NOT, the value is the
  # flag (SmartFolders::Filters::WaitingFilter, BlockingFilter). A value the bar
  # never offers writes no rule.
  def convert_waiting_state(key, values)
    return [] unless values.include?(Tickets::WaitingStateFilter::FLAG_VALUE)

    operator = operator_for(key) == 'not' ? IS_NOT : IS
    [{ field: key, operator: operator, value: Tickets::WaitingStateFilter::FLAG_VALUE }]
  end

  # A rule has no NOT form for a date preset: the condition is skipped and the
  # warning reaches the save row (lib/filter_bar/save_row.js says it beforehand).
  def skip_not(key)
    warnings << I18n.t('services.ad_hoc_to_smart_folder.date_not_skipped', field: key)
    []
  end

  # One rule is a rule. Several are alternatives: one group each (OR), which
  # build_rules_for_groups crosses with the other categories' alternatives.
  def alternatives(rules)
    return rules if rules.size <= 1

    { or_multi: true, field: rules.first[:field], rules: rules }
  end

  # --- Custom attribute converters ---

  def convert_custom_attribute_filter(key, values)
    op = operator_for(key)
    attr_def = project.ticket_attribute_definitions.active.find_by(name: key)
    sf_field = "custom_#{key}"

    if attr_def&.field_type == 'multiselect'
      convert_multiselect(sf_field, values, op)
    else
      convert_select(sf_field, values, op)
    end
  end

  def convert_select(field, values, op)
    joined = values.join(',')

    case op
    when 'not'
      [{ field: field, operator: NOT_IN_LIST, value: joined }]
    else # 'or' is the only valid operator for select
      [{ field: field, operator: IN_LIST, value: joined }]
    end
  end

  def convert_multiselect(field, values, op)
    joined = values.join(',')

    case op
    when 'and'
      # AND: one rule per value with 'contains' operator (AND within same group)
      values.map { |v| { field: field, operator: CONTAINS, value: v } }
    when 'not'
      [{ field: field, operator: NOT_IN_LIST, value: joined }]
    else # 'or'
      [{ field: field, operator: IN_LIST, value: joined }]
    end
  end

  # Preloads referenced records (e.g. Users for assignee rules) to avoid N+1.
  # Returns { 'User' => { id_string => record, ... } }
  def preload_references(rules_by_group)
    user_ids = rules_by_group.flatten
                             .select { |r| %w[assignee creator].include?(r[:field]) }
                             .map { |r| r[:value] }.compact.uniq
    return nil if user_ids.empty?

    users_by_id = organisation.users.where(id: user_ids).index_by { |u| u.id.to_s }
    { 'User' => users_by_id }
  end

  # Returns the validated operator for a filter key.
  def operator_for(key)
    op = operator_params[key].to_s.downcase
    AdHocFilterService::VALID_OPERATORS.include?(op) ? op : AdHocFilterService::DEFAULT_OPERATOR
  end
end
