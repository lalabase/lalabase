# frozen_string_literal: true

# Helper for rendering ad-hoc filter UI components.
# Builds a unified categories JSON for the Stimulus controller.
module AdHocFilterHelper
  FIELD_ICON_MAP = {
    'status' => 'bi-circle',
    'priority' => 'bi-flag',
    'assignee' => 'bi-person',
    'creator' => 'bi-person-badge',
    'tag' => 'bi-tag',
    'created_at' => 'bi-calendar-plus',
    'updated_at' => 'bi-calendar-check',
    'waiting' => 'bi-hourglass-split',
    'blocking' => 'bi-hourglass-split'
  }.freeze
  DEFAULT_FIELD_ICON = 'bi-sliders'

  # Allowed logic operators per field type.
  # select:      OR / NOT (AND is nonsensical for single-select)
  # multiselect: OR / AND / NOT
  # tag:         OR / AND / NOT
  # assignee:    OR / NOT
  # creator:     OR / NOT
  # date:        OR / NOT
  # boolean:     OR / NOT, read "ist" / "ist nicht" (one option, the flag)
  OPERATOR_MAP = {
    'select' => %w[or not],
    'multiselect' => %w[or and not],
    'tag' => %w[or and not],
    'assignee' => %w[or not],
    'creator' => %w[or not],
    'date' => %w[or not],
    'boolean' => %w[or not]
  }.freeze

  # The date presets of created_at/updated_at are SmartFolders::DatePresets::KEYS: the same list
  # is the operator list of the expert filter, so a saved view reads back what the bar offered.

  # Returns all filter categories as JSON for the Stimulus controller.
  # Includes custom attributes (select/multiselect) + special filters.
  # @param project [Project]
  # @return [String] JSON array of category objects
  def ad_hoc_filter_categories_json(project)
    locale = I18n.locale.to_s
    categories = []

    # Custom Attributes (select/multiselect) from TicketAttributeDefinitions
    project.ticket_attribute_definitions
           .active
           .where(field_type: %w[select multiselect])
           .ordered
           .each do |attr_def|
      categories << {
        key: attr_def.name,
        label: attr_def.label_for(locale),
        icon: FIELD_ICON_MAP[attr_def.name] || DEFAULT_FIELD_ICON,
        type: 'custom_attribute',
        allowed_operators: OPERATOR_MAP.fetch(attr_def.field_type, %w[or not]),
        options: attr_def.allowed_values.map do |entry|
          { value: entry['value'], label: entry.dig('labels', locale) || entry['value'] }
        end
      }
    end

    # Assignee (special filter)
    users = project.users_with_access(:read, :tickets)
    sorted_users = users.map { |u| { value: u.id, label: u.display_name } }
                        .sort_by { |o| o[:label].downcase }

    categories << {
      key: 'assignee',
      label: t('views.organisations.tickets.index.filter_assignee'),
      icon: 'bi-person',
      type: 'special',
      allowed_operators: OPERATOR_MAP['assignee'],
      options: sorted_users
    }

    # Creator (special filter) — same user pool as assignee
    categories << {
      key: 'creator',
      label: t('views.organisations.tickets.index.filter_creator'),
      icon: 'bi-person-badge',
      type: 'special',
      allowed_operators: OPERATOR_MAP['creator'],
      options: sorted_users
    }

    # Tags (special filter)
    tag_names = Tag.joins(:taggings)
                   .where(taggings: { taggable_type: 'Ticket', taggable_id: project.tickets.select(:id) })
                   .where(organisation_id: ActsAsTenant.current_tenant&.id)
                   .distinct.order(:name).pluck(:name)
    categories << {
      key: 'tag',
      label: t('views.organisations.tickets.index.filter_tag'),
      icon: 'bi-tag',
      type: 'special',
      allowed_operators: OPERATOR_MAP['tag'],
      options: tag_names.map { |name| { value: name, label: name } },
      empty_hint: t('views.organisations.tickets.index.no_tag_options')
    }

    # Created at (date preset filter)
    date_preset_options = SmartFolders::DatePresets::KEYS.map do |preset|
      { value: preset, label: t("views.organisations.tickets.index.date_preset_#{preset}") }
    end

    categories << {
      key: 'created_at',
      label: t('views.organisations.tickets.index.filter_created_at'),
      icon: 'bi-calendar-plus',
      type: 'special',
      allowed_operators: OPERATOR_MAP['date'],
      options: date_preset_options
    }

    # Updated at (date preset filter)
    categories << {
      key: 'updated_at',
      label: t('views.organisations.tickets.index.filter_updated_at'),
      icon: 'bi-calendar-check',
      type: 'special',
      allowed_operators: OPERATOR_MAP['date'],
      options: date_preset_options
    }

    # Due date (semantic quick-filter) — only when the project has a deadline-marked date field.
    if TicketAttributeDefinition.deadline_definition_for(project)
      due_preset_options = Ticket::DUE_DATE_PRESET_KEYS.map do |preset|
        { value: preset, label: t("views.organisations.tickets.index.due_preset_#{preset}") }
      end
      categories << {
        key: 'due_date',
        label: t('views.organisations.tickets.index.filter_due_date'),
        icon: 'bi-calendar-event',
        type: 'special',
        allowed_operators: OPERATOR_MAP['date'],
        options: due_preset_options
      }
    end

    categories.concat(waiting_state_categories)
    categories.to_json
  end

  private

  # The waiting states (Tickets::WaitingStateFilter): one option, the flag, named like the
  # category, so the save row says "„Wartet“ kam dazu" and a view named after
  # its conditions reads right. The chip says the operator as flag_labels ("ja" / "nein"),
  # where it would otherwise say "nicht <option>" (lib/filter_bar/chip_renderer.js).
  def waiting_state_categories
    flag_labels = { yes: t('views.organisations.tickets.index.filter_flag_yes'),
                    no: t('views.organisations.tickets.index.filter_flag_no') }

    Tickets::WaitingStateFilter::STATES.map do |state|
      label = t("views.organisations.tickets.index.filter_#{state}")
      {
        key: state,
        label: label,
        icon: FIELD_ICON_MAP.fetch(state),
        type: 'special',
        allowed_operators: OPERATOR_MAP['boolean'],
        options: [{ value: Tickets::WaitingStateFilter::FLAG_VALUE, label: label }],
        flag_labels: flag_labels
      }
    end
  end
end
