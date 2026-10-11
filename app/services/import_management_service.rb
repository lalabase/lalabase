# frozen_string_literal: true

class ImportManagementService
  def self.list_import_sessions(organisation)
    new(organisation).list_sessions
  end

  def self.session_details(organisation, session_id)
    new(organisation).session_details(session_id)
  end

  def self.delete_import_session(organisation, session_id)
    new(organisation).delete_session(session_id)
  end

  def initialize(organisation)
    @organisation = organisation
  end

  def list_sessions
    ActsAsTenant.with_tenant(@organisation) do
      ImportedObject
        .group(:import_session_id, :import_source)
        .select(
          :import_session_id,
          :import_source,
          'COUNT(*) AS total_objects',
          'array_agg(DISTINCT DATE(imported_at)) AS import_dates'
        )
        .map do |row|
          {
            import_session_id: row.import_session_id,
            import_source: row.import_source,
            total_objects: row.total_objects,
            import_dates: row.import_dates
          }
        end
    end
  end

  def session_details(session_id)
    ActsAsTenant.with_tenant(@organisation) do
      scope = ImportedObject.by_session(session_id)

      stats = scope.pick(Arel.sql('COUNT(*), MIN(imported_at), MAX(imported_at)'))
      total, first_import, last_import = stats || [0, nil, nil]

      {
        session_id: session_id,
        total_objects: total,
        by_type: scope.group(:importable_type).count,
        objects: scope.order(:imported_at).select(:id, :importable_type, :importable_id, :imported_at, :metadata).map do |obj|
          {
            id: obj.id,
            type: obj.importable_type,
            importable_id: obj.importable_id,
            imported_at: obj.imported_at,
            metadata: obj.metadata
          }
        end,
        first_import: first_import,
        last_import: last_import
      }
    end
  end

  def delete_session(session_id)
    ActsAsTenant.with_tenant(@organisation) do
      result = ImportedObject.delete_import_session(session_id, @organisation.id)

      Rails.logger.debug "Import session #{session_id} deleted: #{result}"
      result
    end
  end

  private

  attr_reader :organisation
end
