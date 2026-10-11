# frozen_string_literal: true

class ImportTimeSessionsFromCodebaseJob < ApplicationJob
  queue_as :default

  def perform(import_file_id, project_id, user_id)
    import_file = CodebaseImportFile.find(import_file_id)
    project = Project.find(project_id)
    user = User.find(user_id)

    result = CodebaseImport::TimeSessionImporter.new(import_file, project, user).call

    if result.success?
      Rails.logger.info "ImportTimeSessionsFromCodebaseJob completed: imported=#{result.imported_count}, skipped=#{result.skipped_count}, errors=#{result.error_count}"
    else
      Rails.logger.error "ImportTimeSessionsFromCodebaseJob failed: #{result.error}"
    end
  rescue StandardError => e
    Rails.logger.error "ImportTimeSessionsFromCodebaseJob exception: #{e.class.name}: #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n")
    mark_import_failed(import_file_id, e.message)
    raise
  end

  private

  def mark_import_failed(import_file_id, error_message)
    import_file = CodebaseImportFile.find_by(id: import_file_id)
    return unless import_file

    import_file.update!(
      status: 'failed',
      error_message: error_message,
      processing_completed_at: Time.current
    )
  end
end
