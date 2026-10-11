# frozen_string_literal: true

# app/models/smart_folder_rule.rb
# == Schema Information
#
# Table name: smart_folder_rules
#
#  id                         :uuid             not null, primary key
#  config                     :jsonb
#  display_value              :text
#  field                      :string           not null
#  operator                   :string           not null
#  position                   :integer          default(1), not null
#  value                      :text
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#  smart_folder_rule_group_id :uuid             not null
#
# Indexes
#
#  idx_on_smart_folder_rule_group_id_position_5c8bc7ff32   (smart_folder_rule_group_id,position)
#  index_smart_folder_rules_on_config                      (config) USING gin
#  index_smart_folder_rules_on_field_and_operator          (field,operator)
#  index_smart_folder_rules_on_smart_folder_rule_group_id  (smart_folder_rule_group_id)
#
# Foreign Keys
#
#  fk_rails_...  (smart_folder_rule_group_id => smart_folder_rule_groups.id)
#
class SmartFolderRule < ApplicationRecord
  include SmartFolders::Operators

  belongs_to :smart_folder_rule_group, inverse_of: :smart_folder_rules

  # Preloaded caches to avoid N+1 queries when building rules in batch.
  # Set by SmartFolderRuleFactory when a precomputed field config or reference
  # map is available (e.g. from AdHocToSmartFolderService).
  attr_accessor :cached_field_config_data, :preloaded_references

  # Tag-ID cache for the TagFilter: the QueryBuilder applies the same Rule instance
  # to multiple model arms (target 'All') — the org-wide tag lookup is
  # identical per arm and is memoized here for one builder run.
  attr_accessor :cached_tag_ids

  # Basic validations
  validates :field, presence: true
  validates :operator, presence: true
  validates :position, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validate :validate_target_field
  validate :validate_field_exists
  validate :validate_operator_for_field
  validate :validate_value_for_operator_and_field

  before_validation :set_default_position, on: :create
  before_save :resolve_display_value, if: -> { value_changed? || field_changed? }
  # Optional: reorder positions after deletion
  # after_destroy :reorder_positions

  delegate :smart_folder, to: :smart_folder_rule_group # Delegates to the group

  # Centralized field configuration as a class method
  # (As provided in the last version, including description and icon)
  def self.field_config
    @field_config ||= {
      'tag' => {
        applicable_types: %w[Note Ticket Document TimeSession],
        operators: [HAS, NOT_HAS, HAS_ANY_OF, HAS_ALL_OF],
        filter_class: 'TagFilter',
        value_type: :text,
        value_required: true,
        description: 'Tag',
        icon: 'tag'
      },
      'participant' => {
        applicable_types: %w[Meeting],
        operators: [EQUALS, NOT_EQUALS, HAS_ANY_OF, HAS_ALL_OF, NOT_HAS],
        filter_class: 'MeetingParticipantFilter',
        value_type: :reference_set,
        value_required: true,
        description: 'Teilnehmer',
        icon: 'people'
      },
      'occurred_at' => {
        applicable_types: %w[Meeting],
        operators: [EQUALS, NOT_EQUALS, BEFORE, AFTER, BETWEEN, WITHIN_DAYS, IN_THE_LAST_DAYS, *SmartFolders::DatePresets::KEYS],
        filter_class: 'DateFilter',
        value_type: :date,
        value_required: true,
        description: 'Meetingdatum',
        icon: 'calendar-event'
      },
      'number' => {
        applicable_types: ['Ticket'],
        operators: [EQUALS, NOT_EQUALS, GREATER_THAN, LESS_THAN, BETWEEN],
        filter_class: 'NumberFilter',
        field_map: { 'Ticket' => 'number' },
        value_type: :number,
        value_required: true,
        description: 'Ticket-Nummer',
        icon: 'hash'
      },
      'title' => {
        applicable_types: %w[Meeting Note Ticket Document],
        operators: [CONTAINS, NOT_CONTAINS, EQUALS, NOT_EQUALS, STARTS_WITH, ENDS_WITH],
        filter_class: 'TextFilter',
        field_map: { 'Meeting' => 'title', 'Note' => 'title', 'Ticket' => 'title', 'Document' => 'title' }, # Assumption: Document.title exists or is fetched from the version
        value_type: :text,
        value_required: true,
        description: 'Titel',
        icon: 'type'
      },
      'content' => {
        applicable_types: %w[Meeting Note Ticket],
        operators: [CONTAINS, NOT_CONTAINS, EQUALS, NOT_EQUALS],
        filter_class: 'ActionTextFilter',
        field_map: { 'Meeting' => 'content', 'Note' => 'content', 'Ticket' => 'content' }, # Both use ActionText content
        value_type: :text,
        value_required: true,
        description: 'Inhalt',
        icon: 'file-text'
      },
      # The date presets (today, this_week, ...) are valueless operators, the same keys the
      # filter bar offers as its quick-filter (SmartFolders::DatePresets), so a view saved from
      # the bar reads back 1:1 and the expert filter edits it.
      'created_at' => {
        applicable_types: %w[Meeting Note Ticket Document TimeSession],
        operators: [EQUALS, NOT_EQUALS, BEFORE, AFTER, BETWEEN, WITHIN_DAYS, IN_THE_LAST_DAYS, *SmartFolders::DatePresets::KEYS],
        filter_class: 'DateFilter',
        value_type: :date,
        value_required: true,
        description: 'Erstellungsdatum',
        icon: 'calendar-plus'
      },
      'updated_at' => {
        applicable_types: %w[Meeting Note Ticket Document TimeSession],
        operators: [EQUALS, NOT_EQUALS, BEFORE, AFTER, BETWEEN, WITHIN_DAYS, IN_THE_LAST_DAYS, *SmartFolders::DatePresets::KEYS],
        filter_class: 'DateFilter',
        value_type: :date,
        value_required: true,
        description: 'Änderungsdatum',
        icon: 'calendar-check'
      },
      # Status and Priority are now handled as custom attributes
      # They can be filtered via the dynamic fields
      'creator' => {
        applicable_types: %w[Meeting Note Ticket Document TimeSession],
        operators: [EQUALS, NOT_EQUALS],
        filter_class: 'AssociationFilter', # simple FK comparison on creator_id
        field_map: {
          'Meeting' => 'creator_id',
          'Note' => 'creator_id',
          'Ticket' => 'creator_id',
          'Document' => 'creator_id',
          'TimeSession' => 'creator_id'
        },
        value_type: :reference,
        value_required: true,
        reference_model: 'User',
        description: 'Erstellt von',
        icon: 'person-badge'
      },
      'assignee' => {
        applicable_types: ['Ticket'],
        operators: [EQUALS, NOT_EQUALS], # Possibly 'is_one_of', 'is_none_of'?
        filter_class: 'AssigneeFilter', # Dedicated filter class for the join logic
        value_type: :reference,
        value_required: true,
        reference_model: 'User',
        description: 'Zugewiesen an',
        icon: 'person'
      },
      'has_time_sessions' => {
        applicable_types: ['Ticket'],
        operators: [IS, IS_NOT],
        filter_class: 'HasTimeSessionsFilter',
        value_type: :boolean,
        value_required: true,
        description: 'Hat Zeitsitzungen',
        icon: 'clock'
      },
      # The waiting states (Tickets::WaitingStateFilter, doc/ticket_relations_plan.md §9).
      'waiting' => {
        applicable_types: ['Ticket'],
        operators: [IS, IS_NOT],
        filter_class: 'WaitingFilter',
        value_type: :boolean,
        value_required: true,
        description: 'Wartet auf offenes Ticket',
        icon: 'hourglass-split'
      },
      'blocking' => {
        applicable_types: ['Ticket'],
        operators: [IS, IS_NOT],
        filter_class: 'BlockingFilter',
        value_type: :boolean,
        value_required: true,
        description: 'Hält andere auf',
        icon: 'hourglass-split'
      },
      'time_session_duration' => {
        applicable_types: ['Ticket'],
        operators: [EQUALS, NOT_EQUALS, GREATER_THAN, LESS_THAN, BETWEEN],
        filter_class: 'TimeSessionFilter',
        value_type: :number,
        value_required: true,
        description: 'Gesamtdauer der Zeitsitzungen (Min)',
        icon: 'hourglass'
      },
      'time_session_count' => {
        applicable_types: ['Ticket'],
        operators: [EQUALS, NOT_EQUALS, GREATER_THAN, LESS_THAN, BETWEEN],
        filter_class: 'TimeSessionFilter',
        value_type: :number,
        value_required: true,
        description: 'Anzahl der Zeitsitzungen',
        icon: 'hash'
      },
      'time_session_billed' => {
        applicable_types: ['Ticket'],
        operators: [IS, IS_NOT],
        filter_class: 'TimeSessionFilter',
        value_type: :boolean,
        value_required: true,
        description: 'Zeitsitzungen abgerechnet',
        icon: 'receipt'
      },
      'duration' => {
        applicable_types: ['TimeSession'],
        operators: [EQUALS, NOT_EQUALS, GREATER_THAN, LESS_THAN, BETWEEN],
        filter_class: 'NumberFilter',
        field_map: { 'TimeSession' => 'duration' }, # Duration in minutes/seconds?
        value_type: :number,
        value_required: true,
        description: 'Dauer (Minuten)', # Add unit
        icon: 'hourglass'
      },
      'billed' => {
        applicable_types: ['TimeSession'],
        operators: [IS, IS_NOT],
        filter_class: 'BooleanFilter',
        field_map: { 'TimeSession' => 'billed_at' }, # Checks for the existence of billed_at? Or a boolean field?
        # Value type depends on the implementation: boolean or date_presence
        value_type: :boolean, # Assumption: there is a boolean field or logic for it
        value_required: true,
        description: 'Abgerechnet',
        icon: 'receipt'
      },
      'version_count' => {
        applicable_types: ['Document'],
        operators: [EQUALS, NOT_EQUALS, GREATER_THAN, LESS_THAN],
        filter_class: 'VersionCountFilter', # Dedicated filter class for the aggregation
        value_type: :number,
        value_required: true,
        description: 'Anzahl Versionen',
        icon: 'layers'
      }
      # TODO: add a field for "Has attachments" if needed
      # 'has_attachments' => { ... }
    }
  end

  def self.operator_label(field, operator)
    I18n.t("smart_folders.field_operators.#{field}.#{operator}",
           default: I18n.t("smart_folders.operators.#{operator}", default: operator.humanize))
  end

  # Extended field configuration with dynamic custom attributes
  # @param organisation [Organisation] The organisation
  # @param project [Project, nil] Optional project - if given, only this project's custom attributes are loaded
  # @param accessible_project_ids [Array, ActiveRecord::Relation, nil] If set, custom
  #   attributes are restricted to these projects (access scoping). Prevents
  #   a user from seeing field names from projects without access in the filter builder.
  def self.field_config_with_custom_attributes(organisation, project = nil, accessible_project_ids: nil)
    base_config = field_config.dup

    # Add dynamic attributes
    if organisation
      scope = TicketAttributeDefinition.active
                                       .joins(:project)
                                       .where(projects: { organisation_id: organisation.id })

      # Restrict to accessible projects (if passed in)
      scope = scope.where(projects: { id: accessible_project_ids }) unless accessible_project_ids.nil?

      # If a project is given, restrict to its attributes
      scope = scope.where(project_id: project.id) if project

      scope.order(:name).each do |attr_def|
        field_key = "custom_#{attr_def.name}"
        is_date = attr_def.field_type.in?(%w[date datetime])

        operators = operators_for_field_type(attr_def.field_type)
        # Deadline-semantic relative operators (valueless, saveable) only on the marked deadline date
        # field — they resolve against Ticket.overdue / the due_date key, so they are meaningless on a
        # non-deadline date field.
        operators += DEADLINE_RELATIVE_OPERATORS if is_date && attr_def.respond_to?(:deadline?) && attr_def.deadline?

        base_config[field_key] = {
          applicable_types: ['Ticket'], # For now, tickets only
          operators: operators,
          # Date custom attributes need date-aware comparison (ISO text, not numeric/containment) and
          # the relative operators — routed to the dedicated CustomAttributeDateFilter.
          filter_class: is_date ? 'CustomAttributeDateFilter' : 'CustomAttributeFilter',
          value_type: value_type_for_field_type(attr_def.field_type),
          value_required: !optional_value_operators(attr_def.field_type).include?(IS_EMPTY),
          description: attr_def.label_for,
          icon: icon_for_field_type(attr_def.field_type),
          attribute_definition: attr_def,
          custom: true # Flag marking it as a custom attribute
        }
      end
    end

    base_config
  end

  # Valueless, relative deadline operators (offered only on the deadline date field). They resolve
  # against "today" / Ticket.overdue, so a saved smart folder using them never goes stale (unlike an
  # absolute "before 2026-06-30"). Reuses the ONE canonical preset list (Ticket::DUE_DATE_PRESET_KEYS)
  # so the SmartFolder operators and the FilterBar quick-filter can never drift apart.
  DEADLINE_RELATIVE_OPERATORS = Ticket::DUE_DATE_PRESET_KEYS

  # Determines the available operators based on the field type
  def self.operators_for_field_type(field_type)
    case field_type
    when 'text', 'textarea', 'richtext'
      [EQUALS, NOT_EQUALS, CONTAINS, NOT_CONTAINS, STARTS_WITH, ENDS_WITH, IS_EMPTY, IS_NOT_EMPTY]
    when 'number', 'currency', 'percentage'
      [EQUALS, NOT_EQUALS, GREATER_THAN, LESS_THAN, BETWEEN, IS_EMPTY, IS_NOT_EMPTY]
    when 'date', 'datetime'
      [EQUALS, NOT_EQUALS, BEFORE, AFTER, BETWEEN, IS_EMPTY, IS_NOT_EMPTY]
    when 'select'
      [EQUALS, NOT_EQUALS, IN_LIST, NOT_IN_LIST, IS_EMPTY, IS_NOT_EMPTY]
    when 'multiselect'
      [CONTAINS, NOT_CONTAINS, IN_LIST, NOT_IN_LIST, IS_EMPTY, IS_NOT_EMPTY]
    when 'checkbox'
      [IS_TRUE, IS_FALSE]
    else
      [EQUALS, NOT_EQUALS] # Fallback
    end
  end

  # Determines the value_type for validation
  def self.value_type_for_field_type(field_type)
    case field_type
    when 'text', 'textarea', 'richtext', 'select', 'multiselect'
      :text
    when 'number', 'currency', 'percentage'
      :number
    when 'date', 'datetime'
      :date
    when 'checkbox'
      :boolean
    else
      :text # Fallback
    end
  end

  # Determines the icon based on the field type
  def self.icon_for_field_type(field_type)
    case field_type
    when 'text', 'textarea', 'richtext'
      'type'
    when 'number', 'currency'
      'calculator'
    when 'percentage'
      'percent'
    when 'date', 'datetime'
      'calendar'
    when 'select', 'multiselect'
      'list'
    when 'checkbox'
      'check-square'
    else
      'gear' # Fallback for custom attributes
    end
  end

  # Operators that do not require a value. The ONE list: the value validator reads it, and the
  # rule builder gets it per field from the field_operators API (as "valueless") instead of
  # keeping a copy.
  def self.optional_value_operators(_field_type = nil)
    [IS_EMPTY, IS_NOT_EMPTY, IS_TRUE, IS_FALSE] + DEADLINE_RELATIVE_OPERATORS + SmartFolders::DatePresets::KEYS
  end

  # Returns the configuration for this specific field
  def field_config
    if field&.start_with?('custom_')
      config_map = cached_field_config_data || begin
        sf = smart_folder_rule_group&.smart_folder
        self.class.field_config_with_custom_attributes(sf&.organisation, sf&.project)
      end
      config_map[field] || {}
    else
      self.class.field_config[field] || {}
    end
  end

  # Helper method for the filter logic: is this rule applicable to the type?
  def applicable_to?(item_type)
    config = field_config
    config.present? && config[:applicable_types]&.include?(item_type)
  end

  # Returns the associated filter strategy class
  def get_filter_class
    config = field_config
    filter_class_name = config[:filter_class]

    unless filter_class_name.present?
      Rails.logger.error "SmartFolderRule Error: No filter_class configured for field '#{field}'"
      return SmartFolders::Filters::BaseFilter # Fallback
    end

    begin
      "SmartFolders::Filters::#{filter_class_name}".constantize
    rescue NameError
      Rails.logger.error "SmartFolderRule Error: Filter class 'SmartFolders::Filters::#{filter_class_name}' not found for field '#{field}'"
      SmartFolders::Filters::BaseFilter # Fallback
    end
  end

  # Returns the actual database column name for a model type
  def get_field_name(item_type)
    config = field_config
    # Special handling for fields that are not a direct column (e.g. aggregations, joins)
    # These fields need special filter logic and are not directly present on the model
    special_fields = %w[
      version_count
      has_time_sessions
      waiting
      blocking
      assignee
      tag
      time_session_duration
      time_session_count
      time_session_billed
    ]

    return nil if special_fields.include?(field)

    field_map = config[:field_map]
    # Use the mapped name if present, otherwise the rule's field name
    field_map && field_map[item_type] ? field_map[item_type] : field
  end

  # Returns a human-readable description of the rule (uses I18n)
  def description
    config = field_config
    field_desc = I18n.t("smart_folders.fields.#{field}", default: config[:description] || field.humanize)
    operator_desc = I18n.t("smart_folders.operators.#{operator}", default: operator.humanize)
    value_desc = display_value.presence || value # Fallback to the raw value

    # Special display for certain operators/types
    case operator
    when *RELATIVE_DATE
      "#{field_desc} #{operator_desc} #{value_desc} Tagen"
    when IS, IS_NOT
      # For boolean values (display value 'Ja'/'Nein' is set by the factory)
      if field_config[:value_type] == :boolean
        "#{field_desc} #{operator_desc} #{value_desc}"
      else
        "#{field_desc} #{operator_desc} \"#{value_desc}\""
      end
    else
      "#{field_desc} #{operator_desc} \"#{value_desc}\"" # Default, with quotation marks
    end
  end

  # Dynamic validations
  private

  # Sets the default position based on existing rules in the group
  def set_default_position
    return unless smart_folder_rule_group && position.blank?

    max_position = smart_folder_rule_group.smart_folder_rules.maximum(:position) || 0
    self.position = max_position + 1
  end

  def validate_target_field
    target = smart_folder_rule_group&.smart_folder&.target_object_type
    return unless target.in?(%w[Meeting All])

    types = target == 'All' ? SmartFolder::ALL_OBJECT_TYPES : ['Meeting']
    errors.add(:field, :unsupported) if (Array(field_config[:applicable_types]) & types).empty?
  end

  # Validates whether the field exists in the configuration
  def validate_field_exists
    if field&.start_with?('custom_')
      config_map = cached_field_config_data || begin
        sf = smart_folder_rule_group&.smart_folder
        self.class.field_config_with_custom_attributes(sf&.organisation, sf&.project)
      end
      errors.add(:field, :unsupported) unless config_map.key?(field)
    else
      errors.add(:field, :unsupported) unless self.class.field_config.key?(field)
    end
  end

  # Validates whether the operator is valid for the chosen field
  def validate_operator_for_field
    config = field_config
    return unless field.present? && config.present? # Only check when the field is valid

    valid_operators = config[:operators]
    return if valid_operators&.include?(operator)

    errors.add(:operator, :invalid_for_field, field: field, valid_operators: valid_operators&.join(', ') || 'keine')
  end

  # Delegates the value validation to the specific validator class
  def validate_value_for_operator_and_field
    config = field_config
    # Only check when the field and operator are valid and a configuration exists
    return unless field.present? && operator.present? && config.present? && config[:operators]&.include?(operator)

    # Special validation for custom attributes with select/radio
    if config[:custom] && config[:attribute_definition]
      attr_def = config[:attribute_definition]
      if %w[select multiselect].include?(attr_def.field_type) && value.present?
        # Fetch the permitted values from allowed_values
        allowed_values = attr_def.allowed_values
        valid_options = allowed_values.map { |opt| opt['value'] }

        # With multiselect or list-membership operators, values can be comma-separated
        if attr_def.field_type == 'multiselect' || LIST_MEMBERSHIP.include?(operator)
          values = value.split(',').map(&:strip)
          invalid_values = values - valid_options
          if invalid_values.any?
            errors.add(:value, :invalid_options, values: invalid_values.join(', '))
            return
          end
        else
          # With select/radio it must be exactly one valid option
          unless valid_options.include?(value)
            errors.add(:value, :must_be_one_of, options: valid_options.join(', '))
            return
          end
        end
      end
    end

    # Find the matching validator based on the value_type
    validator_class = SmartFolders::Validators::ValueValidator.for_field_type(config[:value_type])
    validator = validator_class.new # Instantiate the validator

    # Run the validation
    validator.validate(self, config) # Passes the rule and the field configuration
  end

  # Sets display_value for reference fields (e.g. user name instead of UUID)
  def resolve_display_value
    config = field_config
    return unless config.present?

    case config[:value_type]
    when :reference
      return if value.blank? || config[:reference_model].blank?

      begin
        model_class = config[:reference_model].constantize
        record = preloaded_references&.dig(config[:reference_model], value) ||
                 model_class.find_by(id: value)
        self.display_value = if record
                               case model_class.name
                               when 'User' then record.display_name
                               else record.try(:display_name) || record.try(:name) || record.try(:title) || value
                               end
                             else
                               value
                             end
      rescue NameError
        self.display_value = value
      end
    when :boolean
      self.display_value = value.to_s == 'true' ? I18n.t('generic.yes', default: 'Ja') : I18n.t('generic.no', default: 'Nein')
    else
      self.display_value = value
    end
  end

  # Optional: reorder positions
  # def reorder_positions
  #   return unless smart_folder_rule_group
  #   smart_folder_rule_group.smart_folder_rules.order(:position).each_with_index do |rule, index|
  #     rule.update_column(:position, index + 1) if rule.position != index + 1
  #   end
  # end
end
