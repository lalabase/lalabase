# frozen_string_literal: true

module Organisations
  class CodebaseImportFilesController < Organisations::BaseController
    before_action :require_organisation_admin!
    before_action :set_import_file, only: %i[show destroy preview_import execute_import select_project preview_tickets execute_tickets_import preview_time_sessions execute_time_sessions_import rollback execute_rollback assign_uploads execute_upload_assignment]

    def index
      authorize CodebaseImportFile
      @import_files = policy_scope(current_tenant.codebase_import_files)
                      .includes(:user, :project)
                      .order(created_at: :desc)

      # Group imports by type
      @general_imports = @import_files.general_imports
      @project_imports = @import_files.project_imports.group_by(&:project)
    end

    def new
      @import_file = current_tenant.codebase_import_files.build
      authorize @import_file
      @direct_upload_url = rails_direct_uploads_url if params[:file_type] == 'uploads'
    end

    def create
      @import_file = current_tenant.codebase_import_files.build(import_file_params)
      @import_file.user = current_user
      authorize @import_file

      uploaded_file = params[:codebase_import_file][:file]
      tar_file = params[:codebase_import_file][:tar_file]

      if uploaded_file.blank?
        @import_file.errors.add(:file, t('flash.codebase_import_files.file_required'))
        render :new and return
      end

      # Validate file size for XML
      if uploaded_file.size > CodebaseImportFile::MAX_FILE_SIZE
        @import_file.errors.add(:file, t('flash.codebase_import_files.file_too_large', max: ActionController::Base.helpers.number_to_human_size(CodebaseImportFile::MAX_FILE_SIZE)))
        render :new and return
      end

      # Validate file format for XML
      unless uploaded_file.content_type == 'text/xml' || uploaded_file.original_filename.ends_with?('.xml')
        @import_file.errors.add(:file, t('flash.codebase_import_files.only_xml_allowed'))
        render :new and return
      end

      # Validate TAR file for uploads
      if @import_file.file_type == 'uploads'
        if tar_file.blank?
          @import_file.errors.add(:archive_file, t('flash.codebase_import_files.archive_required'))
          render :new and return
        end

        # Validate archive file size
        max_archive_size = [CodebaseImportFile::MAX_TAR_FILE_SIZE, CodebaseImportFile::MAX_ZIP_FILE_SIZE].max
        if tar_file.size > max_archive_size
          @import_file.errors.add(:archive_file, t('flash.codebase_import_files.archive_too_large', max: ActionController::Base.helpers.number_to_human_size(max_archive_size)))
          render :new and return
        end

        # Validate TAR file format
        allowed_types = ['application/x-tar', 'application/zip']
        allowed_extensions = ['.tar', '.zip']

        unless allowed_types.include?(tar_file.content_type) ||
               allowed_extensions.any? { |ext| tar_file.original_filename.ends_with?(ext) }
          @import_file.errors.add(:archive_file, t('flash.codebase_import_files.only_tar_zip_allowed'))
          render :new and return
        end
      end

      begin
        # Read file content
        @import_file.file_content = uploaded_file.read
        @import_file.original_filename = uploaded_file.original_filename
        @import_file.file_size = uploaded_file.size

        # Process archive file if present
        if params[:archive_file_blob_id].present?
          # Direct Upload - blob already uploaded
          @import_file.archive_file.attach(params[:archive_file_blob_id])
        elsif tar_file.present?
          # Normal upload
          @import_file.archive_file.attach(tar_file)
        end

        # Validate XML format
        doc = Nokogiri::XML(@import_file.file_content)
        if doc.errors.any?
          @import_file.errors.add(:file, t('flash.codebase_import_files.invalid_xml_format'))
          render :new and return
        end

        # Validate specific format depending on type
        if @import_file.file_type == 'users' && !valid_users_xml?(doc)
          @import_file.errors.add(:file, t('flash.codebase_import_files.invalid_users_data'))
          render :new and return
        elsif @import_file.file_type == 'tickets' && !valid_tickets_xml?(doc)
          @import_file.errors.add(:file, t('flash.codebase_import_files.invalid_tickets_data'))
          render :new and return
        elsif @import_file.file_type == 'uploads' && !valid_uploads_xml?(doc)
          @import_file.errors.add(:file, t('flash.codebase_import_files.invalid_uploads_data'))
          render :new and return
        elsif @import_file.file_type == 'time_tracking' && !valid_time_tracking_xml?(doc)
          @import_file.errors.add(:file, t('flash.codebase_import_files.invalid_time_tracking_data'))
          render :new and return
        end

        if @import_file.save
          flash[:notice] = t('flash.codebase_import_files.uploaded', filename: @import_file.original_filename)
          redirect_to organisation_codebase_import_file_path(current_organisation, @import_file)
        else
          render :new
        end
      rescue StandardError => e
        Rails.logger.error "Error processing upload: #{e.message}"
        @import_file.errors.add(:file, t('flash.codebase_import_files.processing_error'))
        render :new
      end
    end

    def show
      authorize @import_file
      @parsed_data = @import_file.parsed_data

      return unless @parsed_data.nil?

      flash[:alert] = t('flash.codebase_import_files.xml_parse_error')
      redirect_to organisation_codebase_import_files_path(current_organisation)
    end

    def destroy
      authorize @import_file
      filename = @import_file.original_filename

      begin
        # Check whether the file is still being processed
        if @import_file.status == 'processing'
          flash[:alert] = t('flash.codebase_import_files.processing_locked')
          redirect_to organisation_codebase_import_files_path(current_organisation) and return
        end

        # Warn if already imported data is present
        imported_objects_count = ImportedObject.from_import_file(@import_file.id).count

        if @import_file.destroy
          message = t('flash.codebase_import_files.deleted', filename: filename)
          message += t('flash.codebase_import_files.deleted_objects_suffix', count: imported_objects_count) if imported_objects_count.positive?
          flash[:notice] = message
        else
          error_messages = @import_file.errors.full_messages.join(', ')
          flash[:alert] = t('flash.codebase_import_files.delete_error', error: error_messages)
        end
      rescue StandardError => e
        Rails.logger.error "Error deleting import file #{@import_file.id}: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        flash[:alert] = t('flash.codebase_import_files.delete_error', error: e.message)
      end

      redirect_to organisation_codebase_import_files_path(current_organisation)
    end

    def preview_import
      authorize @import_file
      unless @import_file.file_type == 'users'
        flash[:alert] = t('flash.codebase_import_files.preview_users_only')
        redirect_to organisation_codebase_import_file_path(current_organisation, @import_file) and return
      end

      return if ensure_not_already_processed!

      @parsed_data = @import_file.parsed_data
      if @parsed_data.nil?
        flash[:alert] = t('flash.codebase_import_files.xml_parse_error')
        redirect_to organisation_codebase_import_file_path(current_organisation, @import_file) and return
      end

      # Ensure default roles exist
      if current_organisation.roles.empty?
        current_organisation.find_or_create_default_role
        current_organisation.find_or_create_account_admin_role
      end

      # Perform user matching
      @user_mappings = CodebaseImport::UserMatcher.new(current_organisation).analyze(@parsed_data)
    end

    def execute_import
      authorize @import_file
      unless @import_file.file_type == 'users'
        flash[:alert] = t('flash.codebase_import_files.import_users_only')
        redirect_to organisation_codebase_import_file_path(current_organisation, @import_file) and return
      end

      return if ensure_not_already_processed!

      import_params = execute_import_params
      user_actions = import_params[:user_actions] || {}
      user_roles = import_params[:user_roles] || {}

      # Start background job for import
      ImportUsersFromCodebaseJob.perform_later(
        @import_file.id,
        user_actions.to_hash,
        user_roles.to_hash,
        current_user.id
      )

      flash[:notice] = t('flash.codebase_import_files.user_import_started')
      redirect_to organisation_codebase_import_file_path(current_organisation, @import_file)
    end

    def select_project
      authorize @import_file

      # For tickets, go directly to the preview with automatic project creation
      if @import_file.file_type == 'tickets'
        redirect_to preview_tickets_organisation_codebase_import_file_path(current_organisation, @import_file)
        return
      end

      # Time tracking still requires project selection
      unless @import_file.file_type == 'time_tracking'
        flash[:alert] = t('flash.codebase_import_files.project_select_time_tracking_only')
        redirect_to organisation_codebase_import_file_path(current_organisation, @import_file) and return
      end

      # Check whether the import has already been processed
      if @import_file.status == 'processed'
        flash[:alert] = t('flash.codebase_import_files.already_imported')
        redirect_to organisation_codebase_import_file_path(current_organisation, @import_file) and return
      end

      @parsed_data = @import_file.parsed_data
      if @parsed_data.blank?
        flash[:alert] = t('flash.codebase_import_files.no_time_entries')
        redirect_to organisation_codebase_import_file_path(current_organisation, @import_file) and return
      end

      @available_projects = selectable_projects.order(:name)
      @item_count = @parsed_data.length
      @item_type = t('flash.codebase_import_files.item_type_time_entries')

      # Extract unique CodebaseHQ project IDs
      @codebase_project_ids = @parsed_data.map { |item| item[:project_id] }.uniq
    end

    def preview_tickets
      authorize @import_file
      unless @import_file.file_type == 'tickets'
        flash[:alert] = t('flash.codebase_import_files.ticket_preview_only')
        redirect_to organisation_codebase_import_file_path(current_organisation, @import_file) and return
      end

      return if ensure_not_already_processed!

      @parsed_data = @import_file.parsed_data
      if @parsed_data.blank?
        flash[:alert] = t('flash.codebase_import_files.no_tickets_found')
        redirect_to organisation_codebase_import_file_path(current_organisation, @import_file) and return
      end

      # Generate automatic project name based on the import file
      timestamp = Time.current.strftime('%Y%m%d_%H%M')
      @suggested_project_name = params[:project_name] || "Import #{timestamp}"

      # Build a temporary project object for the preview (not yet persisted)
      @target_project = current_organisation.projects.build(
        name: @suggested_project_name
      )

      # Analyze custom attribute mappings (use the temporary project)
      @custom_attribute_mappings = analyze_custom_attribute_mappings(@parsed_data, @target_project)

      # Analyze user references
      @user_mappings = analyze_user_references(@parsed_data)

      # Show statistics about the import
      @ticket_count = @parsed_data.length
      @codebase_project_ids = @parsed_data.map { |ticket| ticket[:project_id] }.uniq
    end

    def execute_tickets_import
      authorize @import_file
      unless @import_file.file_type == 'tickets'
        flash[:alert] = t('flash.codebase_import_files.ticket_import_only')
        redirect_to organisation_codebase_import_file_path(current_organisation, @import_file) and return
      end

      return if ensure_not_already_processed!

      import_params = execute_tickets_import_params
      project_name = import_params[:project_name]
      include_tags = ['1', 'true', true].include?(import_params[:include_tags])

      # Validate project name
      if project_name.blank?
        flash[:alert] = t('flash.codebase_import_files.project_name_required')
        redirect_to preview_tickets_organisation_codebase_import_file_path(current_organisation, @import_file) and return
      end

      # Create a new project for the import
      project = current_organisation.projects.build(
        name: project_name
      )

      unless project.save
        flash[:alert] = t('flash.codebase_import_files.project_create_error', error: project.errors.full_messages.join(', '))
        redirect_to preview_tickets_organisation_codebase_import_file_path(current_organisation, @import_file) and return
      end

      # Update the import file with the created project
      @import_file.update!(project_id: project.id)

      # For automatic attribute group creation we use empty mappings
      # The values are automatically taken from the import file
      status_mappings = {}
      priority_mappings = {}

      # Start background job for ticket import
      ImportTicketsFromCodebaseJob.perform_later(
        @import_file.id,
        project.id,
        status_mappings,
        priority_mappings,
        current_user.id,
        include_tags: include_tags
      )

      flash[:notice] = t('flash.codebase_import_files.ticket_import_started', project: project.name)
      redirect_to organisation_codebase_import_file_path(current_organisation, @import_file)
    end

    def preview_time_sessions
      authorize @import_file
      unless @import_file.file_type == 'time_tracking'
        flash[:alert] = t('flash.codebase_import_files.time_preview_only')
        redirect_to organisation_codebase_import_file_path(current_organisation, @import_file) and return
      end

      return if ensure_not_already_processed!

      project_id = params[:project_id]
      if project_id.blank?
        flash[:alert] = t('flash.codebase_import_files.select_project')
        redirect_to select_project_organisation_codebase_import_file_path(current_organisation, @import_file) and return
      end

      @target_project = current_organisation.projects.find(project_id)
      @parsed_data = @import_file.parsed_data

      if @parsed_data.blank?
        flash[:alert] = t('flash.codebase_import_files.no_time_entries')
        redirect_to organisation_codebase_import_file_path(current_organisation, @import_file) and return
      end

      # Analyze the time entries for the preview
      analyze_time_sessions_data
    end

    def execute_time_sessions_import
      authorize @import_file
      unless @import_file.file_type == 'time_tracking'
        flash[:alert] = t('flash.codebase_import_files.time_import_only')
        redirect_to organisation_codebase_import_file_path(current_organisation, @import_file) and return
      end

      return if ensure_not_already_processed!

      import_params = execute_time_sessions_import_params
      project_id = import_params[:project_id]

      if project_id.blank?
        flash[:alert] = t('flash.codebase_import_files.project_required')
        redirect_to select_project_organisation_codebase_import_file_path(current_organisation, @import_file) and return
      end

      target_project = current_organisation.projects.find(project_id)

      # Set project on the import file
      @import_file.update!(project: target_project)

      # Start background job for import
      ImportTimeSessionsFromCodebaseJob.perform_later(
        @import_file.id,
        target_project.id,
        current_user.id
      )

      flash[:notice] = t('flash.codebase_import_files.time_import_started')
      redirect_to organisation_codebase_import_file_path(current_organisation, @import_file)
    end

    def rollback
      authorize @import_file
      unless %w[tickets time_tracking].include?(@import_file.file_type)
        flash[:alert] = t('flash.codebase_import_files.rollback_ticket_time_only')
        redirect_to organisation_codebase_import_file_path(current_organisation, @import_file) and return
      end

      # Check whether this import created any objects at all
      imported_objects = ImportedObject.from_import_file(@import_file.id)

      if imported_objects.empty?
        flash[:alert] = t('flash.codebase_import_files.no_imported_objects')
        redirect_to organisation_codebase_import_file_path(current_organisation, @import_file) and return
      end

      # Show confirmation page with details
      @rollback_summary = {
        tickets: imported_objects.where(importable_type: 'Ticket').count,
        posts: imported_objects.where(importable_type: 'Post').count,
        tags: imported_objects.where(importable_type: 'Tag').count,
        activities: imported_objects.where(importable_type: 'Activity').count,
        total: imported_objects.count
      }

      @import_sessions = imported_objects.group(:import_session_id).count
    end

    def execute_rollback
      authorize @import_file
      unless %w[tickets time_tracking].include?(@import_file.file_type)
        flash[:alert] = t('flash.codebase_import_files.rollback_ticket_time_only')
        redirect_to organisation_codebase_import_file_path(current_organisation, @import_file) and return
      end

      # Find all ImportedObjects for this file
      imported_objects = ImportedObject.from_import_file(@import_file.id)

      if imported_objects.empty?
        flash[:alert] = t('flash.codebase_import_files.no_imported_objects')
        redirect_to organisation_codebase_import_file_path(current_organisation, @import_file) and return
      end

      begin
        # Perform rollback - use the better implementation from ImportedObject
        # This also accounts for tags and has intelligent deletion logic
        session_ids = imported_objects.pluck(:import_session_id).uniq

        rollback_result = if session_ids.size == 1
                            # Single session - normal rollback
                            ImportedObject.delete_import_session(session_ids.first, current_organisation.id)
                          else
                            # Multiple sessions - rollback each and sum results
                            total_result = { posts_deleted: 0, tickets_deleted: 0, tags_deleted: 0, other_deleted: 0, total_deleted: 0 }
                            session_ids.each do |session_id|
                              result = ImportedObject.delete_import_session(session_id, current_organisation.id)
                              total_result[:posts_deleted] += result[:posts_deleted]
                              total_result[:tickets_deleted] += result[:tickets_deleted]
                              total_result[:tags_deleted] += result[:tags_deleted]
                              total_result[:other_deleted] += result[:other_deleted]
                              total_result[:total_deleted] += result[:total_deleted]
                            end
                            total_result
                          end

        # Update import file status
        @import_file.update!(
          status: 'rolled_back',
          metadata: @import_file.metadata.merge({
                                                  'rollback_performed_at' => Time.current,
                                                  'rollback_by_user_id' => current_user.id,
                                                  'rollback_summary' => rollback_result
                                                })
        )

        flash[:notice] = t('flash.codebase_import_files.rollback_success', tickets: rollback_result[:tickets_deleted], posts: rollback_result[:posts_deleted], tags: rollback_result[:tags_deleted])
      rescue StandardError => e
        Rails.logger.error "Rollback failed for import file #{@import_file.id}: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")

        flash[:alert] = t('flash.codebase_import_files.rollback_error', error: e.message)
      end

      redirect_to organisation_codebase_import_file_path(current_organisation, @import_file)
    end

    def assign_uploads
      authorize @import_file
      # Show upload assignment page for a specific project
      @project = Project.find(params[:project_id])

      # Find available upload files
      @upload_files = current_tenant.codebase_import_files
                                    .where(file_type: 'uploads', status: 'uploaded')
                                    .includes(:user)
                                    .order(created_at: :desc)

      # Check whether there are already processed tickets for this project
      @processed_tickets_count = @project.tickets.count

      return unless @processed_tickets_count.zero?

      flash[:alert] = t('flash.codebase_import_files.import_tickets_first')
      redirect_to organisation_codebase_import_files_path(current_organisation) and return
    end

    def execute_upload_assignment
      authorize @import_file
      @project = Project.find(params[:project_id])
      upload_file_id = params[:upload_file_id]

      if upload_file_id.blank?
        flash[:alert] = t('flash.codebase_import_files.select_upload_file')
        redirect_to assign_uploads_organisation_codebase_import_file_path(current_organisation, @import_file, project_id: @project.id) and return
      end

      upload_file = current_tenant.codebase_import_files.find(upload_file_id)

      unless upload_file.file_type == 'uploads'
        flash[:alert] = t('flash.codebase_import_files.not_upload_file')
        redirect_to assign_uploads_organisation_codebase_import_file_path(current_organisation, @import_file, project_id: @project.id) and return
      end

      if upload_file.status == 'processed'
        flash[:alert] = t('flash.codebase_import_files.upload_already_processed')
        redirect_to assign_uploads_organisation_codebase_import_file_path(current_organisation, @import_file, project_id: @project.id) and return
      end

      # Start background job for upload assignment
      AssignUploadsToTicketsJob.perform_later(
        upload_file.id,
        @project.id,
        current_user.id
      )

      flash[:notice] = t('flash.codebase_import_files.upload_assignment_started')
      redirect_to organisation_codebase_import_file_path(current_organisation, upload_file)
    end

    private

    def set_import_file
      @import_file = current_tenant.codebase_import_files.find(params[:id])
    end

    def ensure_not_already_processed!(redirect_path = nil)
      path = redirect_path || organisation_codebase_import_file_path(current_organisation, @import_file)
      if @import_file.status == 'processed'
        flash[:alert] = t('flash.codebase_import_files.already_imported_no_reprocess')
        redirect_to path and return true
      end
      if @import_file.status == 'processing'
        flash[:alert] = t('flash.codebase_import_files.import_running')
        redirect_to path and return true
      end
      false
    end

    def import_file_params
      params.require(:codebase_import_file).permit(:file_type)
    end

    def execute_import_params
      params.permit(
        user_actions: {},
        user_roles: {}
      )
    end

    def execute_tickets_import_params
      params.permit(
        :project_name,
        :include_tags
      )
    end

    def execute_time_sessions_import_params
      params.permit(:project_id)
    end

    def require_organisation_admin!
      # Check whether the user has admin rights in the organisation
      return if current_membership&.role&.title&.downcase&.include?('admin')

      flash[:alert] = t('flash.codebase_import_files.no_import_permission')
      redirect_to root_path
    end

    def valid_users_xml?(doc)
      # Check whether the XML structure for users is correct
      doc.xpath('//users-users/users-user').any? &&
        doc.xpath('//users-user/email-address').any?
    end

    def valid_tickets_xml?(doc)
      # Check whether the XML structure for tickets is correct
      doc.xpath('//tickets-tickets/tickets-ticket').any? &&
        doc.xpath('//tickets-ticket/subject').any?
    end

    def valid_uploads_xml?(doc)
      # Check whether the XML structure for uploads is correct
      doc.xpath('//uploads/upload').any? &&
        doc.xpath('//upload/id').any? &&
        doc.xpath('//upload/file-file-name').any?
    end

    def valid_time_tracking_xml?(doc)
      # Check whether the XML structure for time tracking is correct
      doc.xpath('//time-sessions-sessions/time-sessions-session').any? &&
        doc.xpath('//time-sessions-session/id').any? &&
        doc.xpath('//time-sessions-session/minutes').any?
    end

    def analyze_time_sessions_data
      # Collect statistics about the time entries
      @time_sessions_count = @parsed_data.length
      @total_minutes = @parsed_data.sum { |ts| ts[:minutes] }
      @total_hours = (@total_minutes / 60.0).round(2)

      # Group by user
      @users_summary = @parsed_data.group_by { |ts| ts[:cached_name] || t('flash.codebase_import_files.unknown_user') }
                                   .transform_values do |sessions|
                                     {
                                       count: sessions.length,
                                       total_minutes: sessions.sum { |s| s[:minutes] },
                                       total_hours: (sessions.sum { |s| s[:minutes] } / 60.0).round(2)
                                     }
                                   end

      # Count linked tickets
      @linked_tickets_count = @parsed_data.count { |ts| ts[:ticket_id].present? }
      @unlinked_count = @time_sessions_count - @linked_tickets_count

      # Time frame
      dates = @parsed_data.map do |ts|
        Date.parse(ts[:occurred_on])
      rescue StandardError
        nil
      end.compact
      @date_range = dates.any? ? { from: dates.min, to: dates.max } : nil
    end

    def analyze_custom_attribute_mappings(tickets_data, _target_project)
      # Collect unique values from the import
      unique_statuses = Set.new
      unique_priorities = Set.new

      tickets_data.each do |ticket|
        # Status and priority from the current ticket data
        unique_statuses.add(ticket[:status_cache]) if ticket[:status_cache].present?
        unique_priorities.add(ticket[:priority_cache]) if ticket[:priority_cache].present?

        # Status and priority from the ticket-changes of the updates
        ticket[:updates]&.each do |update|
          ticket_changes = update[:ticket_changes] || {}

          # Collect status changes - in the XML it is called 'status-id', but contains status names
          if ticket_changes['status-id'].present?
            ticket_changes['status-id'].each do |status_value|
              unique_statuses.add(status_value) if status_value.present?
            end
          end

          # Collect priority changes - in the XML it is called 'priority-id', but contains priority names
          next if ticket_changes['priority-id'].blank?

          ticket_changes['priority-id'].each do |priority_value|
            unique_priorities.add(priority_value) if priority_value.present?
          end
        end
      end

      {
        status: {
          attribute_name: t('flash.codebase_import_files.attribute_name_status'),
          values: unique_statuses.to_a.compact
        },
        priority: {
          attribute_name: t('flash.codebase_import_files.attribute_name_priority'),
          values: unique_priorities.to_a.compact
        }
      }
    end

    def analyze_user_references(tickets_data)
      # Collect all user IDs from tickets and updates
      user_ids = Set.new

      tickets_data.each do |ticket|
        user_ids.add(ticket[:reporter_id]) if ticket[:reporter_id].present?
        user_ids.add(ticket[:assignee_id]) if ticket[:assignee_id].present?

        ticket[:updates].each do |update|
          user_ids.add(update[:user_id]) if update[:user_id].present?
        end
      end

      # Find corresponding mappings from previous user imports
      user_mappings = {}
      user_ids.each do |codebase_user_id|
        mapping = CodebaseImportMapping.where(entity_type: 'User')
                                       .where(codebase_id: codebase_user_id)
                                       .first

        user_mappings[codebase_user_id] = mapping
      end

      user_mappings
    end
  end
end
