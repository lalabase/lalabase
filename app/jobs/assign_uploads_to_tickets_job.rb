# frozen_string_literal: true

class AssignUploadsToTicketsJob < ApplicationJob
  queue_as :default

  def perform(upload_import_file_id, project_id, user_id)
    Rails.logger.info "Starting upload assignment job for import file #{upload_import_file_id}"

    upload_import_file = CodebaseImportFile.find(upload_import_file_id)
    project = Project.find(project_id)
    user = User.find(user_id)
    organisation = upload_import_file.organisation

    ActsAsTenant.with_tenant(organisation) do
      mark_as_processing(upload_import_file, project_id)
      execute_assignment(upload_import_file, organisation, project, user)
    end
  end

  private

  def execute_assignment(upload_import_file, organisation, project, user)
    result = CodebaseImport::UploadAssignmentService.new(
      organisation: organisation,
      project: project,
      user: user,
      upload_import_file: upload_import_file
    ).call

    if result[:success]
      mark_as_processed(upload_import_file, result)
    else
      mark_as_failed(upload_import_file, result[:error], result[:errors])
    end
  rescue StandardError => e
    mark_as_failed(upload_import_file, e.message, [])
    raise
  end

  def mark_as_processing(upload_import_file, project_id)
    upload_import_file.update!(
      status: 'processing',
      processing_started_at: Time.current,
      metadata: merge_metadata(upload_import_file,
                               'assignment_started_at' => Time.current,
                               'assignment_project_id' => project_id)
    )
  end

  def mark_as_processed(upload_import_file, result)
    upload_import_file.update!(
      status: 'processed',
      processing_completed_at: Time.current,
      import_summary: {
        'uploads_processed' => result[:processed_count],
        'uploads_errors' => result[:errors].size,
        'assignment_results' => result[:results]
      },
      metadata: merge_metadata(upload_import_file,
                               'assignment_completed_at' => Time.current,
                               'assignment_success' => true)
    )

    Rails.logger.info "Upload assignment completed successfully: #{result[:processed_count]} uploads processed"
  end

  def mark_as_failed(upload_import_file, error_message, errors)
    Rails.logger.error "Upload assignment failed: #{error_message}"

    upload_import_file.update!(
      status: 'failed',
      processing_completed_at: Time.current,
      error_message: error_message,
      metadata: merge_metadata(upload_import_file,
                               'assignment_failed_at' => Time.current,
                               'assignment_errors' => errors)
    )
  end

  def merge_metadata(upload_import_file, new_data)
    (upload_import_file.metadata || {}).merge(new_data)
  end
end
