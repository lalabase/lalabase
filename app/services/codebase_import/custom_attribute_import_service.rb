# frozen_string_literal: true

module CodebaseImport
  class CustomAttributeImportService
    attr_reader :organisation, :user

    def initialize(organisation, user)
      @organisation = organisation
      @user = user
    end

    # Ensures that custom attribute definitions for status and priority exist
    def ensure_import_attributes(project)
      Projects::DefaultAttributeService.new(project).call
    end

    # Adds new values to allowed_values if they do not exist yet
    def add_allowed_value(attribute_name, value, label = nil)
      return if value.blank?

      attribute_def = find_attribute_definition(attribute_name)
      append_allowed_value(attribute_def, value, label) &&
        Rails.logger.debug("CustomAttributeImportService: Added new #{attribute_name} value: #{value}")
    end

    # Adds new values to allowed_values for a specific project
    def add_allowed_value_for_project(attribute_name, value, project)
      return if value.blank?

      attribute_def = find_attribute_definition_for_project(attribute_name, project)
      append_allowed_value(attribute_def, value) &&
        Rails.logger.debug(
          "CustomAttributeImportService: Added new #{attribute_name} value for project #{project.name}: #{value}"
        )
    end

    # Collects all unique values from the ticket data
    def collect_unique_values(tickets_data)
      statuses = Set.new
      priorities = Set.new

      tickets_data.each do |ticket_data|
        # Collect status and priority from current ticket data
        statuses.add(ticket_data[:status_cache]) if ticket_data[:status_cache].present?

        priorities.add(ticket_data[:priority_cache]) if ticket_data[:priority_cache].present?

        # Collect status and priority from the ticket-changes of the updates
        ticket_data[:updates]&.each do |update|
          ticket_changes = update[:ticket_changes] || {}

          # Collect status changes
          if ticket_changes['status-id'].present?
            ticket_changes['status-id'].each do |status_value|
              statuses.add(status_value) if status_value.present?
            end
          end

          # Collect priority changes
          next unless ticket_changes['priority-id'].present?

          ticket_changes['priority-id'].each do |priority_value|
            priorities.add(priority_value) if priority_value.present?
          end
        end
      end

      Rails.logger.debug "CustomAttributeImportService: Collected unique statuses: #{statuses.to_a}"
      Rails.logger.debug "CustomAttributeImportService: Collected unique priorities: #{priorities.to_a}"

      { statuses: statuses.to_a, priorities: priorities.to_a }
    end

    # Preparation of the attributes for a complete import
    def prepare_for_import(project, tickets_data)
      ensure_import_attributes(project)

      unique_values = collect_unique_values(tickets_data)

      # Add all status values
      unique_values[:statuses].each do |status|
        add_allowed_value_for_project('status', status, project)
      end

      # Add all priority values
      unique_values[:priorities].each do |priority|
        add_allowed_value_for_project('priority', priority, project)
      end

      Rails.logger.info "CustomAttributeImportService: Prepared attributes - Statuses: #{unique_values[:statuses].count}, Priorities: #{unique_values[:priorities].count}"
    end

    private

    # Single place where an imported value becomes an option. Returns false when there is
    # nothing to do (no definition, value already known) so the callers can gate their log line.
    #
    # The level handling is the part that matters: a select attribute may carry signal-bar
    # levels (the default priority ships 1=Niedrig … 4=Dringend), and
    # TicketAttributeDefinition#validate_option_levels enforces all-or-nothing. Appending a
    # level-less option to a levelled attribute therefore raised RecordInvalid and aborted the
    # ENTIRE import — any ticket carrying a priority the project did not know yet was enough.
    # An imported value brings no ranking we could trust, so it enters at the lowest level:
    # showing an unknown value as maximum urgency would be the worse lie. Operators can
    # re-rank it in the attribute editor afterwards.
    def append_allowed_value(attribute_def, value, label = nil)
      return false unless attribute_def

      existing_values = attribute_def.allowed_values || []
      return false if existing_values.any? { |opt| opt['value'] == value }

      label ||= value.humanize
      new_option = { 'value' => value, 'labels' => { 'de' => label, 'en' => label } }
      new_option['level'] = 1 if existing_values.any? { |opt| opt['level'].present? }

      attribute_def.options ||= {}
      attribute_def.options['allowed_values'] = existing_values + [new_option]
      attribute_def.save!
      true
    end

    def find_attribute_definition(name)
      @attribute_definition_cache ||= {}
      @attribute_definition_cache[name] ||=
        TicketAttributeDefinition.joins(:project)
                                 .where(projects: { organisation_id: organisation.id })
                                 .find_by(name: name)
    end

    def find_attribute_definition_for_project(name, project)
      @project_attribute_definition_cache ||= {}
      @project_attribute_definition_cache[[name, project.id]] ||=
        project.ticket_attribute_definitions.find_by(name: name)
    end
  end
end
