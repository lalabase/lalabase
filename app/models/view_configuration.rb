# frozen_string_literal: true

# Stores user-specific view configurations for tables and lists. The column
# list of the base view lives here (doc/spaltenwahl_plan.md); a saved view
# carries its own in SmartFolder#display_columns.
#
# A row belongs to one project, or to none: the base view of "Alle Meetings"
# (meetings_uebersicht_vereinheitlichen_plan.md, PR 2) is the one list without a
# project, so only view_type 'meetings' may go without one. project: nil means
# "organisation-wide" everywhere in this class; tickets, notes and documents
# always pass a project.
# == Schema Information
#
# Table name: view_configurations
#
#  id                             :uuid             not null, primary key
#  detail_settings                :jsonb
#  header_columns                 :jsonb
#  list_columns                   :jsonb
#  pinned_columns                 :jsonb
#  table_columns                  :jsonb
#  view_mode                      :string           default("table")
#  view_type                      :string           default("tickets")
#  created_at                     :datetime         not null
#  updated_at                     :datetime         not null
#  kanban_attribute_definition_id :uuid
#  organisation_id                :uuid             not null
#  project_id                     :uuid
#  user_id                        :uuid             not null
#
# Indexes
#
#  index_view_configs_on_user_organisation_type_without_project  (user_id,organisation_id,view_type) UNIQUE WHERE (project_id IS NULL)
#  index_view_configs_on_user_project_type                       (user_id,project_id,view_type) UNIQUE
#  index_view_configurations_on_header_columns                   (header_columns) USING gin
#  index_view_configurations_on_list_columns                     (list_columns) USING gin
#  index_view_configurations_on_organisation_id                  (organisation_id)
#  index_view_configurations_on_project_id                       (project_id)
#  index_view_configurations_on_table_columns                    (table_columns) USING gin
#  index_view_configurations_on_user_id                          (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (kanban_attribute_definition_id => ticket_attribute_definitions.id) ON DELETE => nullify
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (user_id => users.id)
#
class ViewConfiguration < ApplicationRecord
  acts_as_tenant :organisation

  belongs_to :user
  belongs_to :project, optional: true
  belongs_to :kanban_attribute_definition, class_name: 'TicketAttributeDefinition', optional: true

  # View modes for ticket views
  VIEW_MODES = %w[table kanban].freeze

  # Default columns that cannot be disabled
  DEFAULT_REQUIRED_COLUMNS = %w[number title].freeze

  # Default table columns if none configured
  DEFAULT_TABLE_COLUMNS = %w[number title assignees created_at].freeze

  # Minimum width of a column in the header row, in pixels, by key and then by
  # type (doc/spaltenwahl_plan.md, S1). The list carries them as data
  # (data-col-min) so the fit rule in lib/column_picker/fit.js and the compact
  # stylesheet read the same numbers; Tailwind is precompiled, a computed class
  # would not exist.
  #
  # number and title are not competitors here, they are the FLOOR: the fit rule
  # subtracts the two before it asks how many ranked columns are left room for
  # (tickets/index, data-column-picker-fixed-width-value). So the title's number
  # is the answer to "how much of a headline does a reader get before any other
  # column gets anything" - it went 200 -> 320 on 07.09.2026, because with a lane
  # open the title was cut off mid-word while two more columns stood beside it.
  # A wide list is untouched by this: there the room is enough for all of them.
  #
  # ⚠️ 'number' is 48 because the stylesheet says 48 (.list table .number-header).
  # It read 60 for a while after the column was narrowed, and a fit rule that
  # thinks the first column is 22px wider than it is hands that much less to the
  # title, quietly, at every width.
  # custom_status: the project's status column, keyed like every custom column
  # (custom_<name>). A select's 110 cut "In Bearbeitung" next to an open lane
  # (compact mode reads this minimum; full mode reads the share in
  # TicketColumnsHelper::COLUMN_SHARE). 138 = the word at 12px with its dot
  # and gap (~106) plus the cell's 2 x 12px padding (designer, 09.09.2026).
  # A status attribute under another name keeps the select's 110.
  COLUMN_MIN_WIDTH_PX = {
    'number' => 48, 'title' => 320, 'assignees' => 120, 'tags' => 140,
    'created_at' => 110, 'updated_at' => 110, 'time_spent' => 90, 'billing_status' => 140, 'subtask_count' => 70,
    'waiting' => 70, 'custom_status' => 138, 'participants' => 220, 'occurred_at' => 170, 'duration_minutes' => 90,
    'project' => 140
  }.freeze
  COLUMN_MIN_WIDTH_BY_TYPE_PX = {
    'select' => 110, 'multiselect' => 140, 'text' => 140, 'textarea' => 160, 'checkbox' => 70,
    'date' => 110, 'datetime' => 140, 'currency' => 100, 'percentage' => 90, 'number' => 90,
    'users' => 120, 'user' => 120
  }.freeze
  DEFAULT_COLUMN_MIN_WIDTH_PX = 110
  # The selection box column (doc/ticket_bulk_edit_plan.md, slice 1): a fixed
  # cell before the number, only for readers with write access. Its width is
  # handed to the fit script with number and title, or every fit is off by it.
  SELECT_COLUMN_WIDTH_PX = 40
  # The last header cell: the column picker's trigger.
  TRIGGER_CELL_WIDTH_PX = 40

  # Default header columns if none configured
  DEFAULT_HEADER_COLUMNS = %w[assignees tags].freeze

  # The two ticket columns that report booked time. Named as a constant because
  # they are the only columns whose availability depends on the USER, not on the
  # project's configuration (see time_columns_visible_for?).
  TIME_COLUMN_KEYS = %w[time_spent billing_status].freeze

  # The ticket columns whose value is counted from a ticket's CHILDREN. A row
  # showing one of them goes stale when a child changes, so a write to a child
  # redraws its parent's row as well (TicketListColumns#ticket_list_row_streams).
  CHILDREN_COLUMN_KEYS = %w[subtask_count].freeze

  # Detail settings for ticket header display
  DEFAULT_DETAIL_SETTINGS = {
    'assignee_display' => 'full_name',
    'time_display' => 'verbose',
    'heading_date' => 'on',
    'subscriber_display' => 'full_inline',
    'action_bar' => 'show_all',
    'subtasks_display' => 'full',
    'custom_field_display' => {}
  }.freeze

  DETAIL_SETTING_OPTIONS = {
    'assignee_display' => %w[off full_name initials icon_only],
    'time_display' => %w[off compact verbose],
    'heading_date' => %w[off on],
    'subscriber_display' => %w[off compact full_inline],
    'action_bar' => %w[show_all collapsed],
    # full = list always expanded; compact = collapsed, list behind a <details> toggle.
    'subtasks_display' => %w[full compact]
  }.freeze

  validates :view_type, presence: true, inclusion: { in: %w[tickets notes documents meetings] }
  # The list types that have a page without a project.
  ORGANISATION_WIDE_VIEW_TYPES = %w[meetings].freeze

  validates :user_id, uniqueness: { scope: %i[project_id view_type] }, if: :project_id?
  # Without a project the organisation is the scope: the validator reads past
  # the tenant scope, so (project_id, view_type) alone would let a user have
  # one overview row across all their organisations. The database holds the
  # same rule in a partial unique index (NULLs are distinct in the other one).
  validates :user_id, uniqueness: { scope: %i[organisation_id view_type], conditions: -> { where(project_id: nil) } },
                      unless: :project_id?
  validates :project, presence: true, unless: -> { ORGANISATION_WIDE_VIEW_TYPES.include?(view_type) }
  validates :view_mode, inclusion: { in: VIEW_MODES }, allow_nil: true
  validate :kanban_attribute_definition_of_own_project

  # Ensure required columns are always included
  before_save :ensure_required_columns
  before_save :ensure_valid_detail_settings

  # The one ordered list of this view's columns (doc/spaltenwahl_plan.md, D1).
  # Rank is the position; number and title are always first. The second list
  # of the old two-tab modal, `list_columns` (cells, and fields below the
  # title), is folded in behind the table columns until its column is dropped;
  # the next write of table_columns retires it (see ensure_required_columns).
  def ordered_columns
    self.class.normalize_columns(Array(table_columns) + self.class.legacy_list_extras(list_columns), view_type)
  end

  # === Pinned columns (designer, 07.09.2026, "Anpinnen einbauen") ===
  #
  # Which columns stay READABLE when the width runs out: their value moves under
  # the title instead of being dropped. A list of keys beside the ordered list,
  # because the order is what the reader drags and a pin is a different question
  # about the same column.
  #
  # ⚠️ A key that is no longer ticked stays in here on purpose. Unticking a
  # column and ticking it again should not cost the reader the pin - the state
  # is theirs, not a consequence of the tick.
  #
  # Number and title need no entry: they are pinned by definition (see
  # ALWAYS_PINNED), and a constant does not belong in a per-view list.
  ALWAYS_PINNED = %w[number title].freeze

  def pinned_column_keys
    Array(pinned_columns).map(&:to_s)
  end

  def pinned_column_keys=(keys)
    self.pinned_columns = Array(keys).map(&:to_s).uniq - ALWAYS_PINNED
  end

  # The ONE writer of the list. It retires the legacy second list itself:
  # unticking a folded-in field can leave table_columns exactly as stored, so
  # the before_save rule alone would not notice and the field would come back.
  def ordered_columns=(keys)
    self.table_columns = self.class.normalize_columns(keys, view_type)
    self.list_columns = nil
  end

  def self.required_columns_for(view_type)
    case view_type
    when 'meetings', 'notes' then %w[title]
    when 'documents' then %w[name]
    else DEFAULT_REQUIRED_COLUMNS
    end
  end

  # Remove blank and duplicate keys; keep the type-specific required columns first.
  # Shared by stored configurations, saved views and URL drafts.
  def self.normalize_columns(keys, view_type = 'tickets')
    cleaned = Array(keys).map(&:to_s).reject(&:blank?).uniq
    required = required_columns_for(view_type)
    required + (cleaned - required)
  end

  def self.column_min_width(column)
    COLUMN_MIN_WIDTH_PX[column[:key].to_s] || COLUMN_MIN_WIDTH_BY_TYPE_PX[column[:type].to_s] || DEFAULT_COLUMN_MIN_WIDTH_PX
  end

  # The list a base view starts with (plan D7): number, title, the project's
  # status attribute when it has one, who works on it, when it was created.
  # Status is found the way the kanban board finds it, not by name: a
  # project's status column is `custom_<name>`, whatever the name.
  #
  # Meetings: the project page shows title, date, duration and participants;
  # "Alle Meetings" (no project) names each row's project after the title, the
  # list that page showed before it had a column picker.
  def self.default_columns_for(project, view_type = 'tickets')
    if view_type == 'meetings'
      return project ? %w[title occurred_at duration_minutes participants] : %w[title project occurred_at duration_minutes participants]
    end

    status = status_attribute_for(project)
    columns = DEFAULT_REQUIRED_COLUMNS.dup
    columns << "custom_#{status.name}" if status
    columns + %w[assignees created_at]
  end

  # The select attribute whose values carry a status system function, or nil.
  def self.status_attribute_for(project)
    return nil if project.nil?

    status_keys = SystemFunctions::Registry::FUNCTION_CATEGORIES['status'][:functions].map { |f| f[:key] }
    project.ticket_attribute_definitions.active.ordered.where(field_type: %w[select]).detect do |attr_def|
      attr_def.allowed_values.any? { |v| (v['system_functions'] || []).intersect?(status_keys) }
    end
  end

  # Extras from the old second list, in its order: own columns first, then
  # the fields below the title. Either the Hash of the last format or the
  # Array before it; anything else is nothing.
  def self.legacy_list_extras(list)
    case list
    when Hash then Array(list['cells']) + Array(list['metadata'])
    when Array then list
    else []
    end
  end

  # Get available columns specifically for header configuration
  def available_header_columns
    base_header_columns = [
      { key: 'assignees', label: I18n.t('models.view_configuration.columns.assignees'), type: 'users' },
      { key: 'tags', label: I18n.t('models.view_configuration.columns.tags'), type: 'tags' },
      { key: 'created_at', label: I18n.t('models.view_configuration.columns.created_at'), type: 'datetime' },
      { key: 'updated_at', label: I18n.t('models.view_configuration.columns.updated_at'), type: 'datetime' }
    ]

    self.class.append_custom_columns(base_header_columns, project, view_type)
  end

  # Get configuration for a user/project/view combination
  def self.for_user_project(user, project, view_type = 'tickets')
    find_or_initialize_with_defaults(user: user, project: project, view_type: view_type)
  end

  # The row without a project: the base view of a list of the whole
  # organisation ("Alle Meetings"). Only ORGANISATION_WIDE_VIEW_TYPES save.
  def self.for_user_organisation(user, organisation, view_type)
    find_or_initialize_with_defaults(user: user, organisation: organisation, project: nil, view_type: view_type)
  end

  # The base view of the list a caller stands on: its project's row, or the
  # organisation's row when the list has no project. Every write path of the
  # column picker asks this, so the choice is made once.
  def self.for_list(user:, organisation:, project:, view_type:)
    project ? for_user_project(user, project, view_type) : for_user_organisation(user, organisation, view_type)
  end

  def self.find_or_initialize_with_defaults(**attributes)
    find_or_initialize_by(**attributes) do |config|
      config.table_columns = default_columns_for(attributes[:project], attributes[:view_type])
      config.pinned_columns = default_pins_for(attributes[:project], attributes[:view_type])
      config.header_columns = DEFAULT_HEADER_COLUMNS
    end
  end
  private_class_method :find_or_initialize_with_defaults

  # The values a base view keeps readable under the title when its column does
  # not fit. On a meetings list the participants; on "Alle Meetings" the
  # project as well, because a row that cannot name its project there (a phone,
  # a narrow list) says less than the page did before it had a picker.
  def self.default_pins_for(project, view_type)
    return [] unless view_type == 'meetings'

    project ? %w[participants] : %w[project participants]
  end

  # Get all available columns for configuration (instance method)
  #
  # Memoized: resolving the time columns asks TimeSessions::ViewingScope, and a
  # single list render reads this from the controller, the results partial and
  # every row.
  def available_columns
    @available_columns ||= self.class.available_columns_for(project, view_type, user: user)
  end

  # Class method for column availability without an instance
  # Also used by the SmartFolder form
  #
  # user: is needed for the time columns only. Passing none leaves them out,
  # which is the safe direction: a caller that cannot name a user cannot be told
  # what that user is allowed to see.
  def self.available_columns_for(project, view_type = 'tickets', user: nil)
    base = case view_type
           when 'tickets' then ticket_base_columns
           when 'notes' then note_base_columns
           when 'documents' then document_base_columns
           when 'meetings' then meeting_base_columns
           else []
           end

    # Every row of a list without a project names its own (meetings only).
    base += [meeting_project_column] if view_type == 'meetings' && project.nil?

    base += time_columns if view_type == 'tickets' && time_columns_visible_for?(project, user)

    append_custom_columns(base, project, view_type)
  end

  # Booked time and its billing state, as table columns. Values come from
  # TimeSessions::SubjectTotals; the labels for the states are the chip's own
  # (views.time_sessions.billing_status.*), so all three surfaces say one word.
  def self.time_columns
    [
      { key: 'time_spent', label: I18n.t('models.view_configuration.columns.time_spent'), type: 'duration' },
      { key: 'billing_status', label: I18n.t('models.view_configuration.columns.billing_status'),
        type: 'billing_status' }
    ]
  end

  # Hidden outright for a user who may see none of the project's booked time.
  # Offering a column that can only ever render a dash would be worse than not
  # offering it, and the same tier decides what the cells may add up
  # (TimeSessions::ViewingScope is the ONE owner of that question).
  def self.time_columns_visible_for?(project, user)
    return false if project.nil? || user.nil?

    TimeSessions::ViewingScope.call(user: user, project: project).tier != :none
  end

  # --- Detail settings ---

  def detail_settings_parsed
    DEFAULT_DETAIL_SETTINGS.merge(detail_settings || {})
  end

  def detail_setting(key)
    detail_settings_parsed[key.to_s]
  end

  # True when the user collapsed the sub-tasks list. A named predicate so the view does not
  # hard-code the 'compact' magic string and the rule is unit-testable in one place.
  def subtasks_compact?
    detail_setting('subtasks_display') == 'compact'
  end

  # Returns display mode for a custom field: 'off', 'text', or 'colored'
  def custom_field_display_mode(column_key)
    modes = detail_settings_parsed['custom_field_display'] || {}
    modes[column_key] || 'colored'
  end

  # --- Kanban support ---

  def kanban_mode?
    view_mode == 'kanban'
  end

  # Cascade: 1) explicitly configured → 2) auto-detect via System Functions → 3) nil
  def resolved_kanban_attribute
    kanban_attribute_definition || auto_detect_kanban_attribute
  end

  # All select attributes that are suitable as a Kanban column
  def kanban_eligible_attributes
    return TicketAttributeDefinition.none if project.nil?

    project.ticket_attribute_definitions.active.ordered
           .where(field_type: %w[select])
  end

  private

  # Automatically finds a Kanban attribute.
  # Cascade: 1) attribute with status System Functions → 2) first select attribute
  def auto_detect_kanban_attribute
    self.class.status_attribute_for(project) || kanban_eligible_attributes.first
  end

  # TicketAttributeDefinition carries no tenant (it is scoped through its project), so
  # nothing else checks the id from the request: a foreign one put the values and
  # labels of another project's field on this board.
  def kanban_attribute_definition_of_own_project
    return if kanban_attribute_definition_id.blank?
    return unless will_save_change_to_kanban_attribute_definition_id?
    return if project&.ticket_attribute_definitions&.exists?(kanban_attribute_definition_id)

    errors.add(:kanban_attribute_definition, :invalid)
  end

  # Appends custom attribute columns to base when view_type == 'tickets'
  def self.append_custom_columns(base, project, view_type)
    if view_type == 'tickets' && project&.ticket_attribute_definitions&.any?
      custom = project.ticket_attribute_definitions.active.ordered.map do |attr|
        { key: "custom_#{attr.name}", label: attr.label_for, type: attr.field_type, custom: true }
      end
      base + custom
    else
      base
    end
  end

  def self.ticket_base_columns
    [
      { key: 'number', label: I18n.t('models.view_configuration.columns.number'), type: 'number', required: true },
      { key: 'title', label: I18n.t('models.view_configuration.columns.title'), type: 'text', required: true },
      { key: 'assignees', label: I18n.t('models.view_configuration.columns.assignees'), type: 'users' },
      { key: 'tags', label: I18n.t('models.view_configuration.columns.tags'), type: 'tags' },
      { key: 'created_at', label: I18n.t('models.view_configuration.columns.created_at'), type: 'datetime' },
      { key: 'updated_at', label: I18n.t('models.view_configuration.columns.updated_at'), type: 'datetime' },
      # Done and total sub-tickets, "1/3". Counted per page by
      # Tickets::SubtaskCountsCache, not stored: a stored counter drifts past
      # dependent: :nullify and every update_all, and a wrong count looks right.
      { key: 'subtask_count', label: I18n.t('models.view_configuration.columns.subtask_count'), type: 'count' },
      # Open tickets this one waits on, "2" with an hourglass (doc/ticket_relations_plan.md,
      # revision 4, §8.3). Counted per page by Tickets::WaitingCountsCache. Not in
      # CHILDREN_COLUMN_KEYS and not live for other rows: a blocker done elsewhere shows here on
      # the next load (plan §4, no stream for another ticket).
      { key: 'waiting', label: I18n.t('models.view_configuration.columns.waiting'), type: 'count' }
    ]
  end

  def self.meeting_base_columns
    [
      { key: 'title', type: 'text', required: true },
      { key: 'occurred_at', type: 'datetime' },
      { key: 'duration_minutes', type: 'duration' },
      { key: 'participants', type: 'users' },
      { key: 'creator', type: 'user' },
      { key: 'created_at', type: 'datetime' },
      { key: 'updated_at', type: 'datetime' }
    ].map { |column| column.merge(label: I18n.t("models.view_configuration.meeting_columns.#{column[:key]}")) }
  end

  # Offered only on a meetings list without a project (available_columns_for).
  def self.meeting_project_column
    { key: 'project', label: I18n.t('models.view_configuration.meeting_columns.project'), type: 'project' }
  end

  def self.note_base_columns
    [
      { key: 'title', label: I18n.t('models.view_configuration.columns.title'), type: 'text', required: true },
      { key: 'description', label: I18n.t('models.view_configuration.columns.description'), type: 'text' },
      { key: 'created_at', label: I18n.t('models.view_configuration.columns.created_at'), type: 'datetime' },
      { key: 'updated_at', label: I18n.t('models.view_configuration.columns.updated_at'), type: 'datetime' }
    ]
  end

  def self.document_base_columns
    [
      { key: 'name', label: I18n.t('models.view_configuration.columns.name'), type: 'text', required: true },
      { key: 'file_type', label: I18n.t('models.view_configuration.columns.file_type'), type: 'text' },
      { key: 'file_size', label: I18n.t('models.view_configuration.columns.file_size'), type: 'filesize' },
      { key: 'created_at', label: I18n.t('models.view_configuration.columns.uploaded_at'), type: 'datetime' }
    ]
  end

  def ensure_required_columns
    # A write to the list retires the legacy second list: from now on the
    # stored list is complete, and a folded-in field the reader unticked must
    # not come back through the merge in #ordered_columns. The flag is read
    # before normalising, which may change the value on its own.
    columns_written = will_save_change_to_table_columns?
    self.table_columns = self.class.normalize_columns(table_columns, view_type)
    self.list_columns = nil if columns_written && !list_columns.nil?

    # header_columns: filter out blank strings, default if nil
    self.header_columns = (header_columns || DEFAULT_HEADER_COLUMNS).reject(&:blank?)
  end

  def ensure_valid_detail_settings
    return if detail_settings.blank?

    # Convert ActionController::Parameters to Hash if needed
    raw = detail_settings.respond_to?(:to_unsafe_h) ? detail_settings.to_unsafe_h : detail_settings.to_h

    # Preserve custom_field_display hash separately
    custom_display = raw['custom_field_display']

    cleaned = raw.slice(*DETAIL_SETTING_OPTIONS.keys)
    cleaned.each do |key, value|
      cleaned.delete(key) unless DETAIL_SETTING_OPTIONS[key]&.include?(value)
    end

    # Validate and re-add custom_field_display
    if custom_display.is_a?(Hash) || custom_display.respond_to?(:to_unsafe_h)
      display_hash = custom_display.respond_to?(:to_unsafe_h) ? custom_display.to_unsafe_h : custom_display.to_h
      valid_modes = %w[off text colored]
      cleaned['custom_field_display'] = display_hash.select { |_k, v| valid_modes.include?(v) }
    end

    self.detail_settings = cleaned
  end
end
