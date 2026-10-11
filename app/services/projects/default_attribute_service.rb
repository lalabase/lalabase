# frozen_string_literal: true

module Projects
  class DefaultAttributeService
    # Shared so the backfill (Projects::BacklogStatusBackfillService) appends the exact
    # same option to existing projects. Appended LAST in the seed on purpose: the first
    # status option is the de-facto default for new tickets (required select, no blank
    # prompt), and new tickets should start as "Neu", not parked in the backlog.
    BACKLOG_STATUS_OPTION = {
      'value' => 'backlog',
      'labels' => { 'de' => 'Backlog', 'en' => 'Backlog' },
      'color' => '#94A3B8',
      'system_functions' => [SystemFunctions::Registry::IS_BACKLOG]
    }.freeze

    DUE_DATE_LABELS = { 'de' => 'Fälligkeit', 'en' => 'Due date' }.freeze

    # The first status option is the de-facto default for new tickets
    # (required select, no blank prompt). Named here — next to the options it
    # belongs to — so programmatic ticket creation (Actors::SeedOnboarding)
    # references the value instead of duplicating the string.
    DEFAULT_STATUS_VALUE = 'new'

    attr_reader :project

    def initialize(project)
      @project = project
    end

    def call
      create_status_attribute
      create_priority_attribute
      self.class.ensure_due_date(project)
    end

    # Idempotent due-date provisioning, shared by new-project setup and the backfill.
    # Reconciliation (never destructive): if a `due_date` attribute already exists but is
    # NOT a date field, log the conflict and skip — overwriting would lose user data.
    # Returns :created / :exists / :conflict.
    def self.ensure_due_date(project)
      existing = project.ticket_attribute_definitions.find_by(name: Ticket::DUE_DATE_KEY)
      if existing
        return :exists if existing.field_type == 'date'

        Rails.logger.warn(
          "[DefaultAttributeService] project=#{project.id} already has a non-date " \
          "'#{Ticket::DUE_DATE_KEY}' attribute (#{existing.field_type}); skipping due-date provisioning"
        )
        return :conflict
      end

      project.ticket_attribute_definitions.create!(
        name: Ticket::DUE_DATE_KEY,
        field_type: 'date',
        labels: DUE_DATE_LABELS.dup,
        options: { TicketAttributeDefinition::DEADLINE_OPTION_KEY => true },
        position: 3,
        active: true,
        system: true,
        validation_rules: { 'required' => false },
        width: 'half'
      )
      :created
    end

    private

    def create_status_attribute
      return if project.ticket_attribute_definitions.exists?(name: 'status')

      project.ticket_attribute_definitions.create!(
        name: 'status',
        field_type: 'select',
        labels: { 'de' => 'Status', 'en' => 'Status' },
        options: { 'allowed_values' => status_options },
        position: 1,
        active: true,
        system: true,
        validation_rules: { 'required' => true },
        width: 'half'
      )
    end

    def create_priority_attribute
      return if project.ticket_attribute_definitions.exists?(name: 'priority')

      project.ticket_attribute_definitions.create!(
        name: 'priority',
        field_type: 'select',
        labels: { 'de' => 'Priorität', 'en' => 'Priority' },
        options: { 'allowed_values' => priority_options },
        position: 2,
        active: true,
        system: false,
        validation_rules: { 'required' => false },
        width: 'half'
      )
    end

    def status_options
      [
        {
          'value' => DEFAULT_STATUS_VALUE,
          'labels' => { 'de' => 'Neu', 'en' => 'New' },
          'color' => '#3B82F6',
          'system_functions' => [SystemFunctions::Registry::IS_NEW]
        },
        {
          'value' => 'in_progress',
          'labels' => { 'de' => 'In Bearbeitung', 'en' => 'In Progress' },
          'color' => '#F59E0B',
          'system_functions' => [SystemFunctions::Registry::IS_IN_PROGRESS]
        },
        {
          'value' => 'resolved',
          'labels' => { 'de' => 'Erledigt', 'en' => 'Resolved' },
          'color' => '#22C55E',
          'system_functions' => [SystemFunctions::Registry::IS_COMPLETED]
        },
        {
          'value' => 'closed',
          'labels' => { 'de' => 'Geschlossen', 'en' => 'Closed' },
          'color' => '#6B7280',
          'system_functions' => [SystemFunctions::Registry::IS_CLOSED]
        },
        BACKLOG_STATUS_OPTION
      ]
    end

    # `level` drives the signal-bar fill (NeoPriorityBarsComponent): 1=Niedrig … 4=Dringend.
    # Explicit and reorder-independent (the source of truth for bars is the level, not the
    # option position). Existing projects get levels via Projects::PriorityLevelBackfillService.
    def priority_options
      [
        {
          'value' => 'low',
          'labels' => { 'de' => 'Niedrig', 'en' => 'Low' },
          'color' => '#93C5FD',
          'level' => 1
        },
        {
          'value' => 'normal',
          'labels' => { 'de' => 'Normal', 'en' => 'Normal' },
          'color' => '#FCD34D',
          'level' => 2
        },
        {
          'value' => 'high',
          'labels' => { 'de' => 'Hoch', 'en' => 'High' },
          'color' => '#F97316',
          'system_functions' => [SystemFunctions::Registry::HIGH_PRIORITY],
          'level' => 3
        },
        {
          'value' => 'urgent',
          'labels' => { 'de' => 'Dringend', 'en' => 'Urgent' },
          'color' => '#EF4444',
          'system_functions' => [SystemFunctions::Registry::HIGH_PRIORITY],
          'level' => 4
        }
      ]
    end
  end
end
