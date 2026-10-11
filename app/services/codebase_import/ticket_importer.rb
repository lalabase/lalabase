# frozen_string_literal: true

module CodebaseImport
  class TicketImporter
    class ImportError < StandardError; end
    class ValidationError < ImportError; end
    class MappingError < ImportError; end

    attr_reader :import_file, :project, :organisation, :user, :status_mappings, :priority_mappings, :import_session_id, :custom_attribute_service

    def initialize(import_file, project, status_mappings, priority_mappings, user, include_tags: false, **_opts)
      @import_file = import_file
      @project = project
      @organisation = project.organisation
      @user = user
      @status_mappings = status_mappings
      @priority_mappings = priority_mappings
      @import_session_id = SecureRandom.uuid
      @include_tags = include_tags
      @tag_import_service = include_tags ? TagImportService.new(@organisation, @user, @import_session_id) : nil
      @custom_attribute_service = CustomAttributeImportService.new(@organisation, @user)

      validate_inputs!
    end

    def call
      Rails.logger.debug "TicketImporter.call starting for org: #{@organisation.id}"
      ActsAsTenant.with_tenant(@organisation) do
        update_import_status('processing')

        tickets_data = parse_tickets_data
        Rails.logger.debug "TicketImporter: Found #{tickets_data.count} tickets to import"

        Rails.logger.debug 'TicketImporter: Resolving mappings'
        resolved_mappings = resolve_mappings(tickets_data)
        Rails.logger.debug "TicketImporter: Resolved #{resolved_mappings[:statuses].count} statuses, #{resolved_mappings[:priorities].count} priorities"

        import_results = if @include_tags
                           import_tickets_with_tags(tickets_data, resolved_mappings)
                         else
                           import_tickets(tickets_data, resolved_mappings)
                         end

        update_import_status('processed', import_results)

        ImportResult.new(
          success: true,
          imported_count: import_results[:imported_tickets],
          skipped_count: import_results[:skipped_tickets] || 0,
          error_count: import_results[:error_tickets],
          errors: import_results[:errors]
        )
      end
    rescue StandardError => e
      Rails.logger.error "TicketImporter.call exception: #{e.class.name}: #{e.message}"
      Rails.logger.error "TicketImporter backtrace: #{e.backtrace.first(5).join("\n")}"
      handle_error(e)
      ImportResult.new(success: false, error: e.message)
    end

    private

    def validate_inputs!
      raise ValidationError, I18n.t('services.codebase_import.ticket_importer.import_file_required') unless import_file
      raise ValidationError, I18n.t('services.codebase_import.ticket_importer.project_required') unless project
      raise ValidationError, I18n.t('services.codebase_import.ticket_importer.user_required') unless user
      raise ValidationError, I18n.t('services.codebase_import.ticket_importer.status_mappings_required') unless status_mappings.is_a?(Hash)
      raise ValidationError, I18n.t('services.codebase_import.ticket_importer.priority_mappings_required') unless priority_mappings.is_a?(Hash)
    end

    def update_import_status(status, summary = nil)
      case status
      when 'processing'
        import_file.update!(
          status: status,
          processing_started_at: Time.current
        )
      when 'processed'
        import_file.update!(
          status: status,
          processing_completed_at: Time.current,
          import_summary: summary
        )
      when 'failed'
        import_file.update!(
          status: status,
          processing_completed_at: Time.current,
          error_message: summary
        )
      end
    end

    def parse_tickets_data
      tickets_data = import_file.parsed_data
      raise ImportError, I18n.t('services.codebase_import.ticket_importer.no_ticket_data') if tickets_data.blank?

      tickets_data
    end

    def resolve_mappings(tickets_data)
      # Prepare custom attributes directly on the project
      custom_attribute_service.prepare_for_import(project, tickets_data)

      # Convert old ID-based mappings to value-based mappings
      converter = MappingConverter.new(organisation)
      converted_status_mappings = converter.convert_status_mappings(status_mappings)
      converted_priority_mappings = converter.convert_priority_mappings(priority_mappings)

      {
        statuses: CustomAttributeMappingResolver.new(organisation, 'status', converted_status_mappings, custom_attribute_service).resolve,
        priorities: CustomAttributeMappingResolver.new(organisation, 'priority', converted_priority_mappings, custom_attribute_service).resolve
      }
    end

    def import_tickets(tickets_data, resolved_mappings)
      imported_count = 0
      skipped_count = 0
      error_count = 0
      errors = []

      Rails.logger.info "TicketImporter: Processing #{tickets_data.count} tickets"

      # Pre-load existing mappings to avoid N+1 queries
      codebase_ids = tickets_data.map { |td| td[:id].to_s }
      existing_mappings = CodebaseImportMapping.where(
        codebase_id: codebase_ids,
        entity_type: 'Ticket'
      ).index_by(&:codebase_id)

      # Pre-load ticket_attribute_definitions to avoid N+1 during validation
      project.ticket_attribute_definitions.load

      tickets_data.each_with_index do |ticket_data, _index|
        # Check if already imported using pre-loaded mappings
        codebase_id_string = ticket_data[:id].to_s

        if existing_mappings[codebase_id_string]
          skipped_count += 1
          next
        end

        ticket_creator = TicketCreator.new(
          project: project,
          organisation: organisation,
          user: user,
          status_mappings: resolved_mappings[:statuses],
          priority_mappings: resolved_mappings[:priorities],
          import_session_id: import_session_id,
          import_file: import_file,
          custom_attribute_service: custom_attribute_service
        )

        ticket_creator.create(ticket_data, skip_duplicate_check: true)
        imported_count += 1
      rescue StandardError => e
        error_count += 1
        error_message = "Ticket #{ticket_data[:number]}: #{e.message}"
        errors << error_message
        Rails.logger.error "TicketImporter error: #{error_message}"
        Rails.logger.error "TicketImporter error backtrace: #{e.backtrace.first(3).join("\n")}"
      end

      Rails.logger.info "TicketImporter: Completed processing. Imported: #{imported_count}, Skipped: #{skipped_count}, Errors: #{error_count}"

      {
        total_tickets: tickets_data.count,
        imported_tickets: imported_count,
        skipped_tickets: skipped_count,
        error_tickets: error_count,
        errors: errors.first(10),
        project_id: project.id,
        project_name: project.name,
        import_session_id: import_session_id
      }
    end

    # Two-phase import: first create all tags, then tickets with tag assignments
    def import_tickets_with_tags(tickets_data, resolved_mappings)
      imported_count = 0
      skipped_count = 0
      error_count = 0
      errors = []
      tag_result = nil

      begin
        # Phase 1: Tag preparation (bulk creation of all tags)
        tag_result = @tag_import_service&.prepare_tags_from_tickets(tickets_data)

        update_progress_with_tags(0, tickets_data.count, tag_result) if tag_result

        # Pre-load existing mappings to avoid N+1 queries
        codebase_ids = tickets_data.map { |td| td[:id].to_s }
        existing_mappings = CodebaseImportMapping.where(
          codebase_id: codebase_ids,
          entity_type: 'Ticket'
        ).index_by(&:codebase_id)

        # Pre-load ticket_attribute_definitions to avoid N+1 during validation
        project.ticket_attribute_definitions.load

        # Phase 2: Ticket import with tag assignments
        tickets_data.each_with_index do |ticket_data, index|
          # Check if already imported using pre-loaded mappings
          codebase_id_string = ticket_data[:id].to_s

          if existing_mappings[codebase_id_string]
            skipped_count += 1
            next
          end

          create_ticket_with_tags(ticket_data, resolved_mappings)
          imported_count += 1

          # Progress update every 50 tickets
          update_progress_with_tags(index + 1, tickets_data.count, tag_result) if (index + 1) % 50 == 0
        rescue StandardError => e
          error_count += 1
          error_message = "Ticket #{ticket_data[:number]}: #{e.message}"
          errors << error_message
          Rails.logger.error "TicketImporter error: #{error_message}"
          Rails.logger.error "TicketImporter error backtrace: #{e.backtrace.first(3).join("\n")}"
        end

        # Phase 3: Finalize tag tracking
        final_tag_result = @tag_import_service&.finalize_tag_tracking
        tag_result = final_tag_result if final_tag_result
      rescue StandardError => e
        Rails.logger.error "TicketImporter: Two-phase import failed: #{e.message}"
        errors << "Tag import failed: #{e.message}"
      end

      Rails.logger.info "TicketImporter: Completed processing. Imported: #{imported_count}, Skipped: #{skipped_count}, Errors: #{error_count}"

      # Extended results with tag information
      result = {
        total_tickets: tickets_data.count,
        imported_tickets: imported_count,
        skipped_tickets: skipped_count,
        error_tickets: error_count,
        errors: errors.first(10),
        project_id: project.id,
        project_name: project.name,
        import_session_id: import_session_id
      }

      # Add tag statistics if available
      result[:tags] = tag_result.to_summary_hash if tag_result

      result
    end

    def create_ticket_with_tags(ticket_data, resolved_mappings)
      # Create ticket (existing logic)
      ticket_creator = TicketCreator.new(
        project: project,
        organisation: organisation,
        user: user,
        status_mappings: resolved_mappings[:statuses],
        priority_mappings: resolved_mappings[:priorities],
        import_session_id: import_session_id,
        import_file: import_file,
        tag_import_service: @tag_import_service,
        custom_attribute_service: custom_attribute_service
      )

      ticket = ticket_creator.create(ticket_data, skip_duplicate_check: true)

      # Assign tags if present
      @tag_import_service.assign_tags_to_ticket(ticket, ticket_data[:tags]) if ticket_data[:tags].present? && @tag_import_service

      ticket
    end

    def update_progress_with_tags(current, total, tag_result)
      return unless import_file

      percentage = total > 0 ? (current.to_f / total * 100).round(1) : 0

      progress_data = {
        current: current,
        total: total,
        percentage: percentage,
        updated_at: Time.current
      }

      # Add tag information if available
      if tag_result
        progress_data[:tags] = {
          total_found: tag_result.total_tags_found,
          new_created: tag_result.new_tags_created,
          existing_reused: tag_result.existing_tags_reused
        }
      end

      import_file.update!(
        metadata: import_file.metadata.merge('progress' => progress_data)
      )
    end

    def handle_error(error)
      update_import_status('failed', error.message)
      Rails.logger.error "TicketImporter failed: #{error.message}"
      Rails.logger.error error.backtrace.join("\n")
    end

    # Value object for import results
    class ImportResult
      attr_reader :success, :imported_count, :skipped_count, :error_count, :errors, :error

      def initialize(success:, imported_count: 0, skipped_count: 0, error_count: 0, errors: [], error: nil)
        @success = success
        @imported_count = imported_count
        @skipped_count = skipped_count
        @error_count = error_count
        @errors = errors
        @error = error
      end

      def success?
        success
      end

      def failure?
        !success
      end

      def errors?
        error_count.positive? || errors.any?
      end
    end
  end
end
