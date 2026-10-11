# frozen_string_literal: true

module CodebaseImport
  class TicketCreator
    attr_reader :project, :organisation, :user, :status_mappings, :priority_mappings, :import_session_id, :import_file, :tag_import_service, :custom_attribute_service

    def initialize(project:, organisation:, user:, status_mappings:, priority_mappings:, import_session_id: nil, import_file: nil, tag_import_service: nil, custom_attribute_service: nil)
      @project = project
      @organisation = organisation
      @user = user
      @status_mappings = status_mappings
      @priority_mappings = priority_mappings
      @import_session_id = import_session_id || SecureRandom.uuid
      @import_file = import_file
      @tag_import_service = tag_import_service
      @custom_attribute_service = custom_attribute_service
    end

    # @param skip_duplicate_check [Boolean] Skip the duplicate mapping check when the caller
    #   has already verified no mapping exists (e.g. TicketImporter pre-loads mappings in batch).
    def create(ticket_data, skip_duplicate_check: false)
      unless skip_duplicate_check
        # Check if ticket was already imported
        existing_mapping = CodebaseImportMapping.find_by(
          codebase_id: ticket_data[:id].to_s,
          entity_type: 'Ticket'
        )

        if existing_mapping
          ticket = Ticket.find_by(id: existing_mapping.local_id)

          if ticket
            Rails.logger.debug "Ticket already imported (codebase_id: #{ticket_data[:id]})"
            Rails.logger.debug "Found existing ticket ##{ticket.number}"
            return ticket
          else
            Rails.logger.warn 'TicketCreator: Mapping exists but ticket not found, removing stale mapping'
            existing_mapping.destroy
          end
        end
      end

      status_value = resolve_custom_attribute_value('status', ticket_data[:status_cache])
      priority_value = resolve_custom_attribute_value('priority', ticket_data[:priority_cache])
      creator_user = resolve_user_reference(ticket_data[:reporter_id])

      ticket = create_ticket(ticket_data, status_value, priority_value, creator_user)
      create_import_mapping(ticket, ticket_data)
      track_imported_object(ticket, ticket_data)
      import_ticket_updates(ticket, ticket_data[:updates] || [])

      ticket
    end

    private

    def resolve_custom_attribute_value(attribute_type, cache_value)
      return nil if cache_value.blank?

      mappings = attribute_type == 'status' ? status_mappings : priority_mappings
      mapped_value = mappings[cache_value]

      # If no mapping was found, use the original value
      mapped_value || cache_value
    end

    def resolve_user_reference(codebase_user_id)
      return nil if codebase_user_id.blank?

      mapping = CodebaseImportMapping.find_by(
        codebase_id: codebase_user_id.to_s,
        entity_type: 'User'
      )

      return User.find_by(id: mapping.local_id) if mapping

      nil
    end

    def create_ticket(ticket_data, status_value, priority_value, creator_user)
      # Create custom attributes hash
      custom_attributes = {}
      custom_attributes['status'] = status_value if status_value.present?
      custom_attributes['priority'] = priority_value if priority_value.present?

      Rails.logger.debug "TicketCreator: Creating ticket with attributes: number=#{ticket_data[:number]}, title=#{ticket_data[:subject]}, custom_attributes=#{custom_attributes.inspect}"

      begin
        ticket = project.tickets.new(
          number: ticket_data[:number],
          # Cut to the model's bound, visibly: a longer subject would stop the
          # import (Ticket::TITLE_MAX_LENGTH).
          title: ticket_data[:subject]&.truncate(Ticket::TITLE_MAX_LENGTH, omission: '…'),
          summary: ticket_data[:summary],
          custom_attributes: custom_attributes,
          creator: creator_user || user,
          updater: creator_user || user,
          created_at: parse_timestamp(ticket_data[:created_at]),
          updated_at: parse_timestamp(ticket_data[:updated_at])
        )
        ticket.skip_auto_subscribe = true
        ticket.organisation = organisation # Cache association to prevent N+1
        ticket.save!
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error "TicketCreator: Failed to create ticket: #{e.message}"
        Rails.logger.error "TicketCreator: Validation errors: #{e.record.errors.full_messages.join(', ')}"
        raise
      rescue StandardError => e
        Rails.logger.error "TicketCreator: Unexpected error creating ticket: #{e.class.name} - #{e.message}"
        raise
      end

      # Set ActionText content after ticket creation
      if ticket_data[:description].present?
        action_text_content = MarkdownToActionTextService.convert(ticket_data[:description])
        ticket.content = action_text_content
        ticket.save!
      end

      ticket
    end

    def create_import_mapping(ticket, ticket_data)
      # Use create! instead of find_or_create_by to avoid N+1 SELECT queries.
      # Duplicate check is already performed at the top of #create.
      CodebaseImportMapping.create!(
        codebase_id: ticket_data[:id].to_s,
        entity_type: 'Ticket',
        local_id: ticket.id,
        mapping_data: {
          original_data: ticket_data.except(:updates),
          action: 'imported',
          import_file_id: import_file&.id
        }
      )
    rescue ActiveRecord::RecordNotUnique
      # Race condition: another process created the mapping concurrently
      CodebaseImportMapping.find_by!(
        codebase_id: ticket_data[:id].to_s,
        entity_type: 'Ticket'
      )
    end

    def track_imported_object(ticket, ticket_data)
      ImportedObject.create!(
        organisation: organisation,
        importable: ticket,
        import_session_id: import_session_id,
        import_source: 'codebase_hq',
        imported_at: Time.current,
        metadata: {
          original_id: ticket_data[:id],
          original_data: ticket_data.except(:updates),
          import_file_id: import_file&.id,
          import_file_name: import_file&.original_filename
        }
      )
    end

    def import_ticket_updates(ticket, updates_data)
      update_importer = TicketUpdateImporter.new(
        ticket,
        organisation,
        user,
        import_session_id: import_session_id,
        import_file: import_file,
        tag_import_service: tag_import_service,
        custom_attribute_service: custom_attribute_service
      )
      update_importer.import_updates(updates_data)
    end

    def parse_timestamp(timestamp_string)
      return Time.current if timestamp_string.blank?

      begin
        parsed_time = if Time.zone
                        Time.zone.parse(timestamp_string)
                      else
                        Time.zone.parse(timestamp_string) || Time.current
                      end

        parsed_time || Time.current
      rescue StandardError
        Time.current
      end
    end
  end
end
