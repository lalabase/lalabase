# frozen_string_literal: true

class ImportTicketsFromCodebaseJob < ApplicationJob
  queue_as :default

  class OrganisationMismatchError < StandardError; end

  def perform(import_file_id, project_id, status_mappings, priority_mappings, user_id, include_tags: false, **_opts)
    import_file, project, user = load_records(import_file_id, project_id, user_id)

    validate_organisation_match!(project, import_file)

    ActsAsTenant.with_tenant(import_file.organisation) do
      result = CodebaseImport::TicketImporter.new(
        import_file, project, status_mappings, priority_mappings, user,
        include_tags: include_tags
      ).call

      raise result.error if result.failure?
    end
  rescue StandardError => e
    Rails.logger.error "ImportTicketsFromCodebaseJob failed: #{e.class}: #{e.message}"
    raise
  end

  private

  def load_records(import_file_id, project_id, user_id)
    ActsAsTenant.without_tenant do
      [
        CodebaseImportFile.find(import_file_id),
        Project.find(project_id),
        User.find(user_id)
      ]
    end
  end

  def validate_organisation_match!(project, import_file)
    return if project.organisation_id == import_file.organisation_id

    raise OrganisationMismatchError,
          "Project organisation (#{project.organisation_id}) does not match import file organisation (#{import_file.organisation_id})"
  end
end
