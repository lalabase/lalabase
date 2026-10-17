# frozen_string_literal: true

# Analyzes whether a SmartFolder's rules can be dissolved
# into ad-hoc filter chips for the unified filter bar.
#
# "Dissolvable" means all rules use fields/operators that have ad-hoc filter equivalents:
#   - assignee/creator/project (equals/not_equals)
#   - custom_* select/multiselect (equals/in_list/not_in_list/not_equals)
#   - tag (has/not_has/has_any_of/has_all_of)
#   - created_at/updated_at with a date preset operator (SmartFolders::DatePresets),
#     plus the legacy in_the_last_days with 7 or 30
#   - the project's deadline field with a deadline preset operator (Ticket::DUE_DATE_PRESET_KEYS)
#   - waiting/blocking (is/is_not on the flag, Tickets::WaitingStateFilter)
#
# This reads back what AdHocToSmartFolderService writes (the round trip of
# doc/filter_datumsvorgaben_rundlauf_plan.md). "Complex" (non-dissolvable) rules use
# fields like title, content, number, has_time_sessions, duration, billed,
# version_count, or unsupported operators.
#
# Usage:
#   result = SmartFolderDissolver.new(smart_folder, current_user).call
#   result.dissolvable?   # => true/false
#   result.ad_hoc_filters # => { "assignee" => ["user-uuid"], "status" => ["open"] }
#   result.ad_hoc_operators # => { "tag" => "and" }
#   result.complex_rules  # => [SmartFolderRule, ...] (for read-only display)
class SmartFolderDissolver
  include SmartFolders::Operators

  Result = Struct.new(:dissolvable, :ad_hoc_filters, :ad_hoc_operators, :complex_rules, keyword_init: true) do
    alias_method :dissolvable?, :dissolvable
  end

  # Fields that can be dissolved into ad-hoc filters
  DISSOLVABLE_FIELDS = %w[assignee creator project tag created_at updated_at occurred_at participant waiting blocking].freeze

  # Operators supported for dissolution per field
  DISSOLVABLE_OPERATORS = {
    'participant' => [EQUALS, NOT_EQUALS, HAS_ANY_OF, HAS_ALL_OF, NOT_HAS],
    'occurred_at' => [IN_THE_LAST_DAYS, *SmartFolders::DatePresets::KEYS],
    'assignee' => [EQUALS, NOT_EQUALS],
    'creator' => [EQUALS, NOT_EQUALS],
    'project' => [EQUALS, NOT_EQUALS],
    'tag' => [HAS, NOT_HAS, HAS_ANY_OF, HAS_ALL_OF],
    'created_at' => [IN_THE_LAST_DAYS, *SmartFolders::DatePresets::KEYS],
    'updated_at' => [IN_THE_LAST_DAYS, *SmartFolders::DatePresets::KEYS],
    'waiting' => [IS, IS_NOT],
    'blocking' => [IS, IS_NOT]
  }.freeze

  # Reference fields whose multi-group OR pattern (one equals rule per
  # group, possibly as a cross product of multiple fields) is dissolvable
  OR_MULTI_FIELDS = %w[assignee creator project].freeze

  # The built-in date fields; their presets are the operators (SmartFolders::DatePresets)
  DATE_FIELDS = %w[created_at updated_at occurred_at].freeze

  # The bar's categories whose values in ONE group would be AND ("today and yesterday"),
  # which the bar's model (values in a category are OR) cannot say: a second rule on such
  # a key inside one group makes the view complex.
  SINGLE_RULE_KEYS = %w[created_at updated_at occurred_at due_date participant waiting blocking].freeze

  # Custom attribute operators that can be dissolved
  DISSOLVABLE_CUSTOM_OPERATORS = [EQUALS, NOT_EQUALS, IN_LIST, NOT_IN_LIST].freeze

  # Legacy: folders saved before the presets became operators carry
  # in_the_last_days 7 or 30. Read only; the converter no longer writes them,
  # and any other day count stays complex.
  DATE_VALUE_TO_PRESET = {
    '7' => 'last_7_days',
    '30' => 'last_30_days'
  }.freeze

  attr_reader :smart_folder, :current_user

  def initialize(smart_folder, current_user = nil)
    @smart_folder = smart_folder
    @current_user = current_user
  end

  def call
    groups = smart_folder.smart_folder_rule_groups.includes(:smart_folder_rules).order(:position)
    all_rules = groups.flat_map(&:smart_folder_rules)

    return empty_result if all_rules.empty?

    # Detect multi-group OR pattern (e.g. assignee OR with multiple users)
    return analyze_multi_group(groups) if groups.size > 1

    # Single group: check each rule
    analyze_single_group(all_rules)
  end

  private

  def analyze_single_group(rules)
    ad_hoc_filters = {}
    ad_hoc_operators = {}
    complex_rules = []

    rules.each do |rule|
      conversion = convert_rule(rule)
      complex_rules << rule unless conversion && merge_conversion(ad_hoc_filters, ad_hoc_operators, conversion)
    end

    Result.new(
      dissolvable: complex_rules.empty?,
      ad_hoc_filters: ad_hoc_filters,
      ad_hoc_operators: ad_hoc_operators,
      complex_rules: complex_rules
    )
  end

  def analyze_multi_group(groups)
    # Check for the OR-across-groups pattern: several groups, each with the
    # same base rules + one arm per OR key (cross product with several keys,
    # cf. AdHocToSmartFolderService#build_rules_for_groups).
    or_keys = or_multi_keys(groups)
    return dissolve_or_multi_pattern(groups, or_keys) if or_keys.any? && exact_or_product?(groups, or_keys)

    # Check for same-field OR pattern (e.g. "High Prio": 2 groups each with custom_priority equals different value)
    return dissolve_same_field_or_pattern(groups) if same_field_or_pattern?(groups)

    # Multi-group patterns we can't dissolve
    all_rules = groups.flat_map(&:smart_folder_rules)
    Result.new(
      dissolvable: false,
      ad_hoc_filters: {},
      ad_hoc_operators: {},
      complex_rules: all_rules
    )
  end

  # A rule that can stand as one arm of an OR across groups, as [key, value] of
  # the bar's condition: a user reference equals a user, a date field carries a
  # preset, the deadline field carries a deadline preset. Nil for any other rule.
  # Mirror of AdHocToSmartFolderService#alternatives.
  def or_arm(rule)
    if OR_MULTI_FIELDS.include?(rule.field) && rule.operator == EQUALS
      [rule.field, rule.value]
    elsif DATE_FIELDS.include?(rule.field) && SmartFolders::DatePresets.valid?(rule.operator)
      [rule.field, rule.operator]
    elsif rule.field.start_with?('custom_') && Ticket::DUE_DATE_PRESET_KEYS.include?(rule.operator)
      ['due_date', rule.operator]
    end
  end

  def or_arm_key(rule)
    or_arm(rule)&.first
  end

  # Keys where EVERY group carries exactly one arm
  def or_multi_keys(groups)
    keys = groups.flat_map { |group| group.smart_folder_rules.filter_map { |rule| or_arm_key(rule) } }.uniq
    keys.select do |key|
      groups.all? { |group| group.smart_folder_rules.count { |rule| or_arm_key(rule) == key } == 1 }
    end
  end

  # Only a full Cartesian product with identical remaining conditions can be
  # represented by independent chips. Correlated OR groups must stay in the editor.
  def exact_or_product?(groups, keys)
    bases = groups.map do |group|
      group.smart_folder_rules.reject { |rule| keys.include?(or_arm_key(rule)) }
           .map { |rule| [rule.field, rule.operator, rule.value] }.sort
    end
    return false unless bases.uniq.one?

    tuples = groups.map do |group|
      keys.map { |key| or_arm(group.smart_folder_rules.find { |rule| or_arm_key(rule) == key }).last }
    end.uniq
    tuples.size == keys.each_index.map { |index| tuples.map { |tuple| tuple[index] }.uniq.size }.inject(1, :*)
  end

  def dissolve_or_multi_pattern(groups, keys)
    ad_hoc_filters = {}
    ad_hoc_operators = {}
    complex_rules = []

    # Collect the per-key values across all groups (cross-product groups
    # repeat values -> uniq restores the original OR list)
    keys.each do |key|
      values = groups.map do |group|
        or_arm(group.smart_folder_rules.find { |rule| or_arm_key(rule) == key }).last
      end.uniq
      ad_hoc_filters[key] = values
      # Multiple values in OR = default operator (or), no explicit operator needed
    end

    # Process base rules from first group (they're duplicated across groups)
    first_group_rules = groups.first.smart_folder_rules.reject { |rule| keys.include?(or_arm_key(rule)) }
    first_group_rules.each do |rule|
      conversion = convert_rule(rule)
      complex_rules << rule unless conversion && merge_conversion(ad_hoc_filters, ad_hoc_operators, conversion)
    end

    Result.new(
      dissolvable: complex_rules.empty?,
      ad_hoc_filters: ad_hoc_filters,
      ad_hoc_operators: ad_hoc_operators,
      complex_rules: complex_rules
    )
  end

  # Detect: each group has exactly 1 rule, all rules use the same field with equals operator
  # (e.g. "High Prio": group1 = custom_priority equals "high", group2 = custom_priority equals "urgent")
  def same_field_or_pattern?(groups)
    return false unless groups.all? { |g| g.smart_folder_rules.size == 1 }

    fields = groups.map { |g| g.smart_folder_rules.first.field }.uniq
    operators = groups.map { |g| g.smart_folder_rules.first.operator }.uniq

    fields.size == 1 && operators.size == 1 && [EQUALS, IN_LIST, HAS, HAS_ANY_OF].include?(operators.first)
  end

  def dissolve_same_field_or_pattern(groups)
    rules = groups.map { |g| g.smart_folder_rules.first }
    field = rules.first.field
    operator = rules.first.operator
    values = rules.map(&:value)

    ad_hoc_filters = {}
    ad_hoc_operators = {}
    complex_rules = []

    if field.start_with?('custom_')
      attr_name = field.delete_prefix('custom_')
      if DISSOLVABLE_CUSTOM_OPERATORS.include?(operator)
        ad_hoc_filters[attr_name] = values
        # OR is default, no explicit operator needed
      else
        complex_rules.concat(rules)
      end
    elsif DISSOLVABLE_FIELDS.include?(field)
      conversion = convert_multi_value_field(field, operator, values)
      if conversion
        merge_conversion(ad_hoc_filters, ad_hoc_operators, conversion)
      else
        complex_rules.concat(rules)
      end
    else
      complex_rules.concat(rules)
    end

    Result.new(
      dissolvable: complex_rules.empty?,
      ad_hoc_filters: ad_hoc_filters,
      ad_hoc_operators: ad_hoc_operators,
      complex_rules: complex_rules
    )
  end

  # Convert a single SmartFolder rule to ad-hoc filter params.
  # Returns { key:, values:, operator: } or nil if not dissolvable.
  def convert_rule(rule)
    if rule.field.start_with?('custom_')
      convert_custom_rule(rule)
    elsif DISSOLVABLE_FIELDS.include?(rule.field)
      convert_standard_rule(rule)
    end
  end

  def convert_custom_rule(rule)
    # A deadline preset (the valueless operators of the project's deadline field) is the
    # bar's due_date category, whichever the field is called.
    return { key: 'due_date', values: [rule.operator], operator: nil } if Ticket::DUE_DATE_PRESET_KEYS.include?(rule.operator)

    attr_name = rule.field.delete_prefix('custom_')
    return nil unless DISSOLVABLE_CUSTOM_OPERATORS.include?(rule.operator)

    case rule.operator
    when EQUALS
      { key: attr_name, values: [rule.value], operator: nil }
    when NOT_EQUALS
      { key: attr_name, values: [rule.value], operator: 'not' }
    when IN_LIST
      { key: attr_name, values: rule.value.split(',').map(&:strip), operator: nil }
    when NOT_IN_LIST
      { key: attr_name, values: rule.value.split(',').map(&:strip), operator: 'not' }
    end
  end

  def convert_standard_rule(rule)
    allowed_ops = DISSOLVABLE_OPERATORS[rule.field]
    return nil unless allowed_ops&.include?(rule.operator)

    case rule.field
    when *OR_MULTI_FIELDS
      convert_reference_rule(rule)
    when 'participant'
      op = { NOT_EQUALS => 'not', NOT_HAS => 'not', HAS_ALL_OF => 'and' }[rule.operator]
      { key: 'participant', values: Meetings::ParticipantFilter.rule_values(rule.value), operator: op }
    when 'tag'
      convert_tag_rule(rule)
    when *DATE_FIELDS
      convert_date_rule(rule)
    when *Tickets::WaitingStateFilter::STATES
      convert_waiting_state_rule(rule)
    end
  end

  # The bar has one value for a waiting state, the flag, and says the rest with its operator:
  # "is true" and "is_not false" are "ist", the other two "ist nicht".
  def convert_waiting_state_rule(rule)
    present = SmartFolders::Filters::WaitingStateFilter.wants_state?(rule)
    { key: rule.field, values: [Tickets::WaitingStateFilter::FLAG_VALUE], operator: present ? nil : 'not' }
  end

  def convert_reference_rule(rule)
    case rule.operator
    when EQUALS
      { key: rule.field, values: [rule.value], operator: nil }
    when NOT_EQUALS
      { key: rule.field, values: [rule.value], operator: 'not' }
    end
  end

  def convert_tag_rule(rule)
    case rule.operator
    when HAS
      { key: 'tag', values: [rule.value], operator: nil }
    when NOT_HAS
      tag_values = rule.value.include?(',') ? rule.value.split(',').map(&:strip) : [rule.value]
      { key: 'tag', values: tag_values, operator: 'not' }
    when HAS_ANY_OF
      { key: 'tag', values: rule.value.split(',').map(&:strip), operator: nil }
    when HAS_ALL_OF
      { key: 'tag', values: rule.value.split(',').map(&:strip), operator: 'and' }
    end
  end

  # A preset operator is the preset; the legacy in_the_last_days reads as 7 or 30 days.
  def convert_date_rule(rule)
    return { key: rule.field, values: [rule.operator], operator: nil } if SmartFolders::DatePresets.valid?(rule.operator)
    return nil unless rule.operator == IN_THE_LAST_DAYS

    preset = DATE_VALUE_TO_PRESET[rule.value]
    return nil unless preset

    { key: rule.field, values: [preset], operator: nil }
  end

  def convert_multi_value_field(field, operator, values)
    case field
    when *OR_MULTI_FIELDS
      case operator
      when EQUALS
        { key: field, values: values, operator: nil }
      when NOT_EQUALS
        { key: field, values: values, operator: 'not' }
      end
    when 'tag'
      case operator
      when HAS, HAS_ANY_OF
        { key: 'tag', values: values, operator: nil }
      when NOT_HAS
        { key: 'tag', values: values, operator: 'not' }
      when HAS_ALL_OF
        { key: 'tag', values: values, operator: 'and' }
      end
    end
  end

  # Merges one converted rule into the condition set. False when it cannot be
  # merged: a second rule on a SINGLE_RULE_KEYS key inside one group (see there).
  def merge_conversion(filters, operators, conversion)
    key = conversion[:key]
    return false if SINGLE_RULE_KEYS.include?(key) && filters.key?(key)

    if filters.key?(key) && OR_MULTI_FIELDS.include?(key)
      previous_operator = operators[key] || 'or'
      next_operator = conversion[:operator] || 'or'
      return false unless previous_operator == next_operator
      return false if next_operator != 'not' && filters[key] != conversion[:values]
    end

    filters[key] ||= []
    filters[key].concat(conversion[:values])
    operators[key] = conversion[:operator] if conversion[:operator]
    true
  end

  def empty_result
    Result.new(
      dissolvable: true,
      ad_hoc_filters: {},
      ad_hoc_operators: {},
      complex_rules: []
    )
  end
end
