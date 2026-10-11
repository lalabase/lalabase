# frozen_string_literal: true

module CodebaseImport
  class TimeSessionImporter
    class ImportError < StandardError; end
    class ValidationError < ImportError; end
    class MappingError < ImportError; end

    attr_reader :import_file, :project, :organisation, :user, :import_session_id

    def initialize(import_file, project, user)
      @import_file = import_file
      @project = project
      @user = user

      validate_inputs!

      @organisation = project.organisation
      @import_session_id = SecureRandom.uuid
    end

    def call
      Rails.logger.debug "TimeSessionImporter.call starting for project: #{@project.id}, org: #{@organisation.id}"
      ActsAsTenant.with_tenant(@organisation) do
        update_import_status('processing')

        time_sessions_data = parse_time_sessions_data
        Rails.logger.info "TimeSessionImporter: Found #{time_sessions_data.count} time sessions to import"

        # Prepare mappings for users and tickets
        mappings = prepare_mappings(time_sessions_data)
        Rails.logger.info "TimeSessionImporter: Prepared mappings - users: #{mappings[:users].count}, tickets: #{mappings[:tickets].count}"

        import_results = import_time_sessions(time_sessions_data, mappings)
        Rails.logger.info "TimeSessionImporter: Import results: #{import_results}"

        update_import_status('processed', import_results)

        ImportResult.new(
          success: true,
          imported_count: import_results[:imported_time_sessions],
          skipped_count: import_results[:skipped_time_sessions],
          error_count: import_results[:error_time_sessions],
          errors: import_results[:errors]
        )
      end
    rescue StandardError => e
      Rails.logger.error "TimeSessionImporter.call exception: #{e.class.name}: #{e.message}"
      Rails.logger.error "TimeSessionImporter backtrace: #{e.backtrace.first(5).join("\n")}"
      handle_error(e)
      ImportResult.new(success: false, error: e.message)
    end

    private

    def validate_inputs!
      raise ValidationError, I18n.t('services.codebase_import.time_session_importer.import_file_required') unless import_file
      raise ValidationError, I18n.t('services.codebase_import.time_session_importer.project_required') unless project
      raise ValidationError, I18n.t('services.codebase_import.time_session_importer.user_required') unless user
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

    def parse_time_sessions_data
      time_sessions_data = import_file.parsed_data
      raise ImportError, I18n.t('services.codebase_import.time_session_importer.no_time_session_data') if time_sessions_data.blank?

      time_sessions_data
    end

    def prepare_mappings(time_sessions_data)
      # Collect all unique user IDs and ticket IDs from the data
      user_ids = time_sessions_data.map { |ts| ts[:user_id] }.uniq.compact
      ticket_ids = time_sessions_data.map { |ts| ts[:ticket_id] }.uniq.compact

      {
        users: prepare_user_mappings(user_ids),
        tickets: prepare_ticket_mappings(ticket_ids),
        time_session_groups: prepare_time_session_group_mappings(time_sessions_data)
      }
    end

    def prepare_user_mappings(codebase_user_ids)
      mappings = {}

      # Fetch existing mappings from the DB
      existing_mappings = CodebaseImportMapping.where(
        codebase_id: codebase_user_ids.map(&:to_s),
        entity_type: 'User'
      )

      existing_mappings.each do |mapping|
        mappings[mapping.codebase_id] = mapping.local_id
      end

      Rails.logger.info "TimeSessionImporter: Found #{mappings.count} existing user mappings"
      mappings
    end

    def prepare_ticket_mappings(codebase_ticket_ids)
      mappings = {}

      # Fetch existing mappings from the DB
      existing_mappings = CodebaseImportMapping.where(
        codebase_id: codebase_ticket_ids.map(&:to_s),
        entity_type: 'Ticket'
      )

      existing_mappings.each do |mapping|
        mappings[mapping.codebase_id] = mapping.local_id
      end

      Rails.logger.info "TimeSessionImporter: Found #{mappings.count} existing ticket mappings"
      mappings
    end

    def prepare_time_session_group_mappings(time_sessions_data)
      mappings = {}

      # Collect all unique billed-group-ids
      group_ids = time_sessions_data.map { |ts| ts[:billed_group_id] }.uniq.compact

      # Create a TimeSessionGroup for each billed-group-id if it does not exist yet
      group_ids.each do |codebase_group_id|
        existing_mapping = CodebaseImportMapping.find_by(
          codebase_id: codebase_group_id.to_s,
          entity_type: 'TimeSessionGroup'
        )

        if existing_mapping
          mappings[codebase_group_id.to_s] = existing_mapping.local_id
        else
          # Create new group
          group = TimeSessionGroup.create!(
            name: "Import Group #{codebase_group_id}",
            description: "Imported from CodebaseHQ (ID: #{codebase_group_id})",
            billed: false,
            organisation: organisation,
            creator: user
          )

          # Create mapping
          CodebaseImportMapping.create!(
            codebase_id: codebase_group_id.to_s,
            local_id: group.id,
            entity_type: 'TimeSessionGroup',
            mapping_data: {
              import_session_id: import_session_id,
              created_at: Time.current
            }
          )

          # Tracking for rollback
          ImportedObject.create!(
            organisation: organisation,
            importable: group,
            import_session_id: import_session_id,
            import_source: 'codebase_time_sessions',
            imported_at: Time.current,
            metadata: { codebase_id: codebase_group_id }
          )

          mappings[codebase_group_id.to_s] = group.id
        end
      end

      Rails.logger.info "TimeSessionImporter: Created/mapped #{mappings.count} time session groups"
      mappings
    end

    def import_time_sessions(time_sessions_data, mappings)
      imported_count = 0
      skipped_count = 0
      error_count = 0
      errors = []

      # Batch-fetch all existing TimeSession mappings to avoid per-item queries
      all_codebase_ids = time_sessions_data.map { |ts| ts[:id].to_s }
      existing_ts_mappings = CodebaseImportMapping.where(
        codebase_id: all_codebase_ids,
        entity_type: 'TimeSession'
      ).pluck(:codebase_id).to_set

      # Pre-load all creator users referenced by mappings to avoid per-item User queries
      creator_local_ids = mappings[:users].values.uniq
      @cached_creators = User.where(id: creator_local_ids).index_by(&:id)

      time_sessions_data.each_with_index do |time_session_data, index|
        # Check if already imported (using pre-fetched set)
        if existing_ts_mappings.include?(time_session_data[:id].to_s)
          skipped_count += 1
          next
        end

        create_time_session(time_session_data, mappings)
        imported_count += 1

        # Progress update every 50 entries
        update_progress(index + 1, time_sessions_data.count) if (index + 1) % 50 == 0
      rescue StandardError => e
        error_count += 1
        error_message = "Time Session #{time_session_data[:id]}: #{e.message}"
        errors << error_message
        Rails.logger.error "TimeSessionImporter error: #{error_message}"
        Rails.logger.error "TimeSessionImporter error backtrace: #{e.backtrace.first(3).join("\n")}"
      end

      Rails.logger.info "TimeSessionImporter: Completed processing. Imported: #{imported_count}, Skipped: #{skipped_count}, Errors: #{error_count}"

      {
        total_time_sessions: time_sessions_data.count,
        imported_time_sessions: imported_count,
        skipped_time_sessions: skipped_count,
        error_time_sessions: error_count,
        errors: errors.first(10),
        project_id: project.id,
        project_name: project.name,
        import_session_id: import_session_id
      }
    end

    def create_time_session(time_session_data, mappings)
      # Map User — use cached creator objects to avoid per-item User queries
      creator_id = mappings[:users][time_session_data[:user_id].to_s]
      creator = if creator_id
                  @cached_creators[creator_id] || user
                else
                  Rails.logger.warn "TimeSessionImporter: No user mapping found for codebase user #{time_session_data[:user_id]}, using import user"
                  user
                end

      # Map Ticket (optional)
      ticket_id = nil
      if time_session_data[:ticket_id].present?
        ticket_id = mappings[:tickets][time_session_data[:ticket_id].to_s]
        Rails.logger.warn "TimeSessionImporter: No ticket mapping found for codebase ticket #{time_session_data[:ticket_id]}" if ticket_id.blank?
      end

      # Map TimeSessionGroup (optional)
      time_session_group_id = nil
      time_session_group_id = mappings[:time_session_groups][time_session_data[:billed_group_id].to_s] if time_session_data[:billed_group_id].present?

      # Create TimeSession — pass association objects to avoid N+1 from acts_as_tenant validation
      time_session = TimeSession.create!(
        occurred_on: parse_date(time_session_data[:occurred_on]),
        duration: time_session_data[:minutes].to_i,
        description: time_session_data[:summary] || 'Imported from CodebaseHQ',
        project: project,
        ticket_id: ticket_id,
        creator: creator,
        organisation: organisation,
        time_session_group_id: time_session_group_id,
        created_at: parse_datetime(time_session_data[:created_at]) || Time.current,
        updated_at: parse_datetime(time_session_data[:updated_at]) || Time.current
      )

      # Create import mapping
      CodebaseImportMapping.create!(
        codebase_id: time_session_data[:id].to_s,
        local_id: time_session.id,
        entity_type: 'TimeSession',
        mapping_data: {
          import_session_id: import_session_id,
          original_user_id: time_session_data[:user_id],
          original_ticket_id: time_session_data[:ticket_id],
          original_billed_group_id: time_session_data[:billed_group_id],
          cached_name: time_session_data[:cached_name],
          cached_email: time_session_data[:cached_email]
        }
      )

      # Tracking for rollback
      ImportedObject.create!(
        organisation: organisation,
        importable: time_session,
        import_session_id: import_session_id,
        import_source: 'codebase_time_sessions',
        imported_at: Time.current,
        metadata: {
          codebase_id: time_session_data[:id],
          original_user_id: time_session_data[:user_id],
          original_ticket_id: time_session_data[:ticket_id]
        }
      )

      time_session
    end

    def parse_date(date_string)
      return nil if date_string.blank?

      Date.parse(date_string)
    rescue ArgumentError
      Rails.logger.warn "TimeSessionImporter: Invalid date format: #{date_string}"
      Date.current
    end

    def parse_datetime(datetime_string)
      return nil if datetime_string.blank?

      Time.parse(datetime_string)
    rescue ArgumentError
      Rails.logger.warn "TimeSessionImporter: Invalid datetime format: #{datetime_string}"
      nil
    end

    def update_progress(current, total)
      return unless import_file

      percentage = total > 0 ? (current.to_f / total * 100).round(1) : 0

      progress_data = {
        current: current,
        total: total,
        percentage: percentage,
        updated_at: Time.current
      }

      import_file.update!(
        metadata: import_file.metadata.merge('progress' => progress_data)
      )
    end

    def handle_error(error)
      update_import_status('failed', error.message)
      Rails.logger.error "TimeSessionImporter failed: #{error.message}"
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
