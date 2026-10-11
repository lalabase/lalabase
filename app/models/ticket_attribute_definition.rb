# frozen_string_literal: true

# Defines custom attributes for tickets that can be configured per project
# Supports multiple field types, validation rules, and multilingual labels
#
# Read path map for this whole area: docs/architektur/tickets_lesepfad.md
#
# This class carries the semantics of ticket status and priority: the options stored here
# reference system functions (SystemFunctions::Registry, which lives under
# app/models/concerns/system_functions/ — the Resolver lives under app/services/, so the
# mechanism is split across two namespaces).
# == Schema Information
#
# Table name: ticket_attribute_definitions
#
#  id               :uuid             not null, primary key
#  active           :boolean          default(TRUE)
#  field_type       :string           not null
#  labels           :jsonb
#  name             :string           not null
#  options          :jsonb
#  position         :integer          default(0)
#  section          :string
#  system           :boolean          default(FALSE)
#  validation_rules :jsonb
#  visibility_rules :jsonb
#  width            :string           default("full")
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  project_id       :uuid             not null
#
# Indexes
#
#  index_ticket_attribute_definitions_on_position               (position)
#  index_ticket_attribute_definitions_on_project_id             (project_id)
#  index_ticket_attribute_definitions_on_project_id_and_active  (project_id,active)
#  index_ticket_attribute_definitions_on_project_id_and_name    (project_id,name) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (project_id => projects.id)
#
class TicketAttributeDefinition < ApplicationRecord
  # Tenant scoping happens through project (which has acts_as_tenant :organisation)
  # No direct organisation_id column on this table

  # Constants
  FIELD_TYPES = %w[
    select
    multiselect
    checkbox
    text
    date
  ].freeze

  # Strict ISO date-only shape (YYYY-MM-DD). Date values are stored as ISO strings in
  # the custom_attributes jsonb, so lexicographic ordering equals chronological ordering
  # and overdue/sort SQL needs no ::date cast. Enforcing this shape on write keeps that
  # invariant true (rejects unpadded dates, datetimes, and garbage).
  ISO_DATE_FORMAT = /\A\d{4}-\d{2}-\d{2}\z/

  # Options-jsonb key that marks a `date` field as "the deadline" of its project. In v1
  # the SQL/JSON key for sort+overdue is pinned to Ticket::DUE_DATE_KEY; this marker is a
  # per-project feature flag + v2 generalization seam. A project has at most one marked
  # date field — enforced by the single-deadline switch (see #enforce_single_deadline_marker).
  DEADLINE_OPTION_KEY = 'deadline'

  WIDTHS = %w[full half third quarter].freeze

  # The only shape an option colour may take: `#` plus six hex digits, either case (the
  # defaults are upper case). It ends up inside a `style` attribute, so anything looser is
  # an injection point (stored XSS, security test 26.09.2026). `\A...\z`, never `^...$`:
  # `$` matches before a newline and would let "#123456\n<script>" through.
  OPTION_COLOR_FORMAT = /\A#\h{6}\z/

  # What an option without a (valid) colour gets in the editor and on save.
  OPTION_COLOR_FALLBACK = '#000000'

  # The one gate every output of an option colour goes through: the value when it is a hex
  # colour, the fallback otherwise. Rows written before the validation existed (or past it,
  # with update_column) are only safe if the reading side checks too.
  def self.safe_option_color(value, fallback = nil)
    value.is_a?(String) && value.match?(OPTION_COLOR_FORMAT) ? value : fallback
  end

  # Associations
  belongs_to :project
  has_one :organisation, through: :project

  # Validations
  validates :name, presence: true,
                   uniqueness: { scope: :project_id },
                   format: { with: /\A[a-z][a-z0-9_]*\z/, message: :lowercase_underscore }
  validate :validate_label_presence
  validate :name_not_reserved, if: :name_changed?
  validates :field_type, presence: true, inclusion: { in: FIELD_TYPES }
  validates :width, inclusion: { in: WIDTHS }
  validates :position, numericality: { greater_than_or_equal_to: 0 }

  # Scopes
  scope :active, -> { where(active: true) }
  scope :for_ticket_type, lambda { |type|
    where("visibility_rules = '{}' OR visibility_rules @> ?", { ticket_type: type }.to_json)
  }
  scope :ordered, -> { order(:position, :created_at) }
  scope :by_section, ->(section) { where(section: section) }

  # Status lifecycle System Functions. "Closed" = done (completed/closed);
  # "backlog" = not started yet. Both are distinct semantically but neither
  # counts as "active work right now".
  CLOSED_SYSTEM_FUNCTIONS = [
    SystemFunctions::Registry::IS_COMPLETED,
    SystemFunctions::Registry::IS_CLOSED
  ].freeze

  BACKLOG_SYSTEM_FUNCTIONS = [
    SystemFunctions::Registry::IS_BACKLOG
  ].freeze

  # The one reader of the status options: { project_id => { downcased `status` value =>
  # its status System Functions } }, the functions in registry order, an option without
  # any with []. Two options whose values differ only in case share a key and their
  # functions. Resolution is scoped to the `status` attribute only —
  # SystemFunctions::Resolver aggregates across all select fields, so a lifecycle function
  # on a non-status field would otherwise leak in. A project without an active status
  # select has no key. project_ids may be an array or a relation (it becomes a subquery,
  # no extra round trip). Values are for comparison with LOWER(custom_attributes->>'status').
  def self.status_functions_by_project(project_ids)
    where(project_id: project_ids, active: true, name: 'status', field_type: 'select')
      .pluck(:project_id, :options)
      .to_h do |project_id, opts|
        by_value = Hash.new { |hash, value| hash[value] = [] }
        ((opts || {})['allowed_values'] || []).each do |opt|
          by_value[opt['value'].to_s.downcase] |= Array(opt['system_functions'])
        end
        [project_id, by_value.transform_values { |fns| SystemFunctions::Registry::STATUS_FUNCTIONS & fns }]
      end
  end

  # Generic, per project: { project_id => downcased `status` values whose option carries any
  # of the given System Functions }. Only flattens the reader above.
  def self.status_values_by_project_with_functions(project_ids, functions)
    status_functions_by_project(project_ids).transform_values do |by_value|
      by_value.filter_map { |value, fns| value if fns.intersect?(functions) }
    end
  end

  # The same values pooled across the given projects. Only right while the projects agree
  # on what a value means; across projects (ticket relations) use the per-project variant.
  def self.status_values_with_functions(project_ids, functions)
    status_values_by_project_with_functions(project_ids, functions).values.flatten.uniq
  end

  def self.closed_status_values_for(project_ids)
    status_values_with_functions(project_ids, CLOSED_SYSTEM_FUNCTIONS)
  end

  # "Done" per project (doc/ticket_relations_plan.md §5.2): { project_id => values }.
  def self.closed_status_values_by_project(project_ids)
    status_values_by_project_with_functions(project_ids, CLOSED_SYSTEM_FUNCTIONS)
  end

  def self.backlog_status_values_for(project_ids)
    status_values_with_functions(project_ids, BACKLOG_SYSTEM_FUNCTIONS)
  end

  # Callbacks
  before_validation :set_defaults
  before_validation :generate_name_from_label, on: :create
  validate :validate_system_functions
  validate :validate_name_immutable_when_in_use
  # Normalize-on-write keeps jsonb flags real types (HTML checkboxes post "0"/"1", and in
  # Ruby the string "0" is truthy; level inputs post strings). before_validation so the
  # validations below see normalized values. The switch keeps at most one deadline per project.
  before_validation :normalize_deadline_marker, if: -> { field_type == 'date' }
  before_validation :normalize_option_levels, if: -> { %w[select multiselect].include?(field_type) }
  validate :validate_option_levels
  validate :validate_option_colors
  after_save :enforce_single_deadline_marker, if: -> { field_type == 'date' && deadline? && saved_change_to_options? }

  # Check if any tickets use this attribute's name as a key
  def in_use?
    persisted? && project.tickets.where('custom_attributes ? :key', key: name).exists?
  end

  # Get label for current locale with fallback
  def label_for(locale = I18n.locale)
    labels[locale.to_s] ||
      labels[I18n.default_locale.to_s] ||
      name.humanize
  end

  # Get placeholder for current locale
  def placeholder_for(locale = I18n.locale)
    return nil unless options['placeholders']

    options['placeholders'][locale.to_s] ||
      options['placeholders'][I18n.default_locale.to_s]
  end

  # Get help text for current locale
  def help_text_for(locale = I18n.locale)
    return nil unless options['help_texts']

    options['help_texts'][locale.to_s] ||
      options['help_texts'][I18n.default_locale.to_s]
  end

  # Check if attribute should be visible for given ticket
  def visible_for?(ticket)
    return true if visibility_rules.blank?

    visibility_rules.all? do |key, value|
      case key
      when 'ticket_type'
        ticket.ticket_type == value
      when 'has_attribute'
        ticket.custom_attributes[value].present?
      when 'attribute_equals'
        ticket.custom_attributes[value['attribute']] == value['value']
      else
        true
      end
    end
  end

  # Check if attribute is required for given ticket
  def required_for?(ticket)
    return false unless validation_rules['required']

    # Check conditional requirements
    if validation_rules['required_if']
      condition = validation_rules['required_if']
      return ticket.custom_attributes[condition['attribute']] == condition['value']
    end

    validation_rules['required'] == true
  end

  # Required for every ticket, with no condition. The `required` flag alone is
  # also set on conditional requirements (required_for? reads it first), so a
  # test on the flag alone would be misleadingly true; a conditional
  # requirement depends on the ticket and is not strict.
  def strictly_required?
    validation_rules['required'] == true && validation_rules['required_if'].blank?
  end

  # Validate a value according to the rules
  def validate_value(value, ticket = nil)
    errors = []

    # Required validation
    errors << I18n.t('errors.messages.blank') if required_for?(ticket) && value.blank?

    return errors if value.blank?

    # Type-specific validations
    case field_type
    when 'select'
      validate_select_value(value, errors)
    when 'multiselect'
      validate_multiselect_value(value, errors)
    when 'date'
      validate_date_value(value, errors)
    end

    errors
  end

  # Get allowed values for select fields
  def allowed_values
    return [] unless %w[select multiselect].include?(field_type)

    options['allowed_values'] || []
  end

  # Stored value keys in configured option order. This is the canonical order used
  # to sort tickets by this attribute (see Ticket#ordered_by_custom_attribute).
  def ordered_value_keys
    allowed_values.map { |option| option['value'] }
  end

  # Configured option order for a project's select attribute (e.g. 'status', 'priority'),
  # or [] when no such active select attribute exists. Single lookup shared by both
  # ticket sorting paths (TicketsController and TicketSearchQuery).
  def self.ordered_value_keys_for(project, attr_name)
    select_for(project, attr_name)&.ordered_value_keys || []
  end

  # The project's active single select of that name, or nil. What list_tickets
  # reads the status keys from and what update_ticket writes a status into.
  def self.select_for(project, attr_name)
    active.find_by(project: project, name: attr_name, field_type: 'select')
  end

  # True when this date field is flagged as its project's deadline. Defensive boolean
  # coercion so a raw/legacy marker ("1"/"true"/"0") reads correctly even if unnormalized.
  def deadline?
    field_type == 'date' && ActiveModel::Type::Boolean.new.cast(options[DEADLINE_OPTION_KEY]) == true
  end

  # The single date field marked as the project's deadline, or nil. In-memory filter over
  # the project's active date fields. List/board call sites should resolve through the
  # per-ticket memoized attribute_definitions (CustomAttributable) to avoid N+1.
  def self.deadline_definition_for(project)
    active.where(project: project, field_type: 'date').detect(&:deadline?)
  end

  # Priority "level" of a stored select value, as { index:, total: }, or nil when the value
  # has no level. `index` = the option's explicit level (1-based, reorder-independent),
  # `total` = the highest level configured on this field. Drives the signal-bar fill — see
  # NeoPriorityBarsComponent. Explicit level (not option position) is the source of truth.
  def level_for(value)
    option = allowed_values.find { |opt| opt['value'] == value }
    level = option && option['level']
    return nil if level.nil?

    { index: level.to_i, total: max_level }
  end

  # Highest configured option level on this field (0 when none carry a level).
  def max_level
    allowed_values.filter_map { |opt| opt['level'] }.map(&:to_i).max || 0
  end

  # Returns the System Functions for a given option value.
  # Stored as an array in the JSONB structure of each option:
  #   { "value": "Hoch", "system_functions": ["high_priority"] }
  # See SystemFunctions::Registry for valid keys.
  def system_functions_for(value)
    option = allowed_values.find { |v| v['value'] == value }
    return [] unless option

    option['system_functions'] || []
  end

  # Get display value for a stored value
  def display_value(value, locale = I18n.locale)
    return value unless %w[select multiselect].include?(field_type)

    if field_type == 'multiselect' && value.is_a?(Array)
      value.map { |v| display_single_value(v, locale) }.join(', ')
    else
      display_single_value(value, locale)
    end
  end

  private

  def generate_name_from_label
    return if name.present?

    source = labels&.dig('en').presence || labels&.dig('de').presence
    return unless source

    base = source.parameterize(separator: '_')
    base = "field_#{base}" if base.match?(/\A[^a-z]/)
    base = 'field' if base.blank?

    candidate = base
    counter = 1
    while self.class.where(project_id: project_id, name: candidate).exists?
      counter += 1
      candidate = "#{base}_#{counter}"
    end

    self.name = candidate
  end

  def set_defaults
    self.labels ||= {}
    self.options ||= {}
    self.validation_rules ||= {}
    self.visibility_rules ||= {}
  end

  # The filter bar reads these keys as its waiting states (Tickets::WaitingStateFilter), never
  # as a field of the project: a field of that name could not be picked in the bar, would
  # filter nothing and would drop out of a saved view. Checked on create and rename only, so a
  # row written before the check stays editable. The older special keys (due_date, ...) are in
  # use as field names and are not reserved here.
  def name_not_reserved
    errors.add(:name, :reserved) if Tickets::WaitingStateFilter::STATES.include?(name)
  end

  def validate_label_presence
    return if labels&.dig('de').present? || labels&.dig('en').present?

    errors.add(:labels, :at_least_one_required)
  end

  def validate_system_functions
    return unless %w[select multiselect].include?(field_type)

    allowed_values.each do |option|
      functions = option['system_functions']
      next if functions.blank?

      functions.each do |func_key|
        next if SystemFunctions::Registry.valid?(func_key)

        errors.add(:options, :invalid_system_function, func_key: func_key, option: option['value'])
      end

      # Backlog ("not started yet") contradicts a done state (completed/closed) on the
      # SAME option. completed+closed may coexist — they are both "done", so that is
      # redundant, not contradictory (e.g. an "abgenommen" status legitimately carries
      # both). Only backlog-vs-done is rejected. Earlier this forbade "more than one of
      # {completed, closed, backlog}", which wrongly broke existing done+closed options
      # (surfaced by the deploy backfill in production).
      if functions.include?(SystemFunctions::Registry::IS_BACKLOG) &&
         functions.intersect?(CLOSED_SYSTEM_FUNCTIONS)
        errors.add(:options, :lifecycle_function_conflict, option: option['value'])
      end
    end
  end

  def validate_name_immutable_when_in_use
    return unless persisted? && name_changed?
    return unless project.tickets.where('custom_attributes ? :key', key: name_was).exists?

    errors.add(:name, :immutable_when_in_use)
  end

  def validate_select_value(value, errors)
    allowed = allowed_values.map { |v| v['value'] }
    errors << I18n.t('errors.messages.inclusion') unless allowed.include?(value)
  end

  def validate_multiselect_value(values, errors)
    return errors << I18n.t('errors.messages.invalid') unless values.is_a?(Array)

    allowed = allowed_values.map { |v| v['value'] }
    invalid_values = values - allowed

    return unless invalid_values.any?

    errors << I18n.t('errors.messages.inclusion')
  end

  # Accept only a strict ISO date-only string (YYYY-MM-DD). The regex guard rejects
  # unpadded dates and datetime strings (Date.iso8601 alone would happily parse the
  # date portion of "2026-06-30T12:00:00Z"); the parse guard rejects impossible dates
  # like "2026-13-40". Blank already short-circuited in #validate_value.
  def validate_date_value(value, errors)
    str = value.to_s
    parsed = begin
      (Date.iso8601(str) if str.match?(ISO_DATE_FORMAT))
    rescue StandardError
      nil
    end
    errors << I18n.t('activerecord.errors.models.ticket_attribute_definition.invalid_date', default: 'is not a valid date') if parsed.nil?
  end

  # Coerce the deadline marker to a real boolean before persisting (HTML checkboxes post
  # "0"/"1" strings; "0" is truthy in Ruby). Leaves options untouched when no marker is set.
  def normalize_deadline_marker
    return unless options.key?(DEADLINE_OPTION_KEY)

    self.options = options.merge(DEADLINE_OPTION_KEY => ActiveModel::Type::Boolean.new.cast(options[DEADLINE_OPTION_KEY]) == true)
  end

  # Coerce option `level` values to integers before validation (admin inputs post strings).
  # Garbage coerces to nil, which the level validation then rejects as missing.
  def normalize_option_levels
    return unless options.is_a?(Hash) && options['allowed_values'].is_a?(Array)

    normalized = options['allowed_values'].map do |option|
      next option unless option.is_a?(Hash) && option.key?('level')

      option.merge('level' => Integer(option['level'], exception: false))
    end
    self.options = options.merge('allowed_values' => normalized)
  end

  # Once ANY option carries a level, ALL must — and each must be an integer in 1..count.
  # This keeps the signal bars unambiguous (contiguous, bounded). Fields with no levels at
  # all are unaffected (a plain select without bars).
  def validate_option_levels
    return unless %w[select multiselect].include?(field_type)

    levels = allowed_values.map { |option| option['level'] }
    return if levels.all?(&:nil?)

    count = allowed_values.size
    levels.each do |level|
      if level.nil?
        errors.add(:options, :level_incomplete)
      elsif !level.is_a?(Integer) || level < 1 || level > count
        errors.add(:options, :level_out_of_range)
      end
    end
  end

  # A colour is optional, but when present it must be a hex colour (OPTION_COLOR_FORMAT).
  def validate_option_colors
    return unless %w[select multiselect].include?(field_type)

    allowed_values.each do |option|
      color = option.is_a?(Hash) ? option['color'] : nil
      next if color.nil? || color == ''
      next if self.class.safe_option_color(color)

      errors.add(:options, :invalid_option_color, option: option['value'])
    end
  end

  # Single-deadline switch: marking this date field as the deadline unsets the marker on
  # every other date field in the same project (last-marked wins). update_column bypasses
  # callbacks (no recursion) and validation. Best-effort under concurrency; a DB partial
  # unique index is the v2 hardening (see plan §11). Scoped to field_type 'date' so select
  # fields are never touched.
  def enforce_single_deadline_marker
    self.class.where(project_id: project_id, field_type: 'date').where.not(id: id).find_each do |other|
      next unless other.deadline?

      other.update_column(:options, other.options.except(DEADLINE_OPTION_KEY)) # intentional: data-only marker unset, bypass callbacks to avoid recursion
    end
  end

  def display_single_value(value, locale)
    option = allowed_values.find { |v| v['value'] == value }
    return value unless option

    # dig: an option without labels (older or hand-made definitions) shows its
    # stored value instead of raising.
    option.dig('labels', locale.to_s) ||
      option.dig('labels', I18n.default_locale.to_s) ||
      value
  end
end
