# frozen_string_literal: true

# Assigns the Codebase import mappings that predate their organisation column
# (migration 20260916120000) to an organisation, and reports what it cannot
# assign plus the imported bookings an earlier import linked across
# organisations. An operator task over all organisations
# (bin/rails codebase_import:scope_mappings), never user-facing, hence
# without_tenant. dry_run: true computes the same report and writes nothing.
#
# - Ticket, TimeSession and TimeSessionGroup mappings take the organisation of
#   the record they point at. A mapping whose record is gone stays unassigned
#   (and invisible): a new import creates the record again.
# - A User mapping is assigned only when the user is a member of exactly one
#   organisation that has Codebase import files. Anything else stays
#   unassigned; running the user import in that organisation maps the
#   Codebase users again by e-mail.
# - Bookings are only reported, never changed: which ticket a wrongly linked
#   booking should point at is a decision for the organisation.
module CodebaseImport
  class MappingOrganisationBackfill
    RECORD_MODELS = [Ticket, TimeSession, TimeSessionGroup].freeze
    SAMPLE_SIZE = 20

    Report = Struct.new(:assigned, :unassigned, :foreign_links, keyword_init: true)

    def self.call(dry_run: true)
      new(dry_run: dry_run).call
    end

    def initialize(dry_run: true)
      @dry_run = dry_run
    end

    def call
      ActsAsTenant.without_tenant do
        report = nil
        CodebaseImportMapping.transaction do
          assigned = RECORD_MODELS.to_h { |model| [model.name, assign_by_record(model)] }
          assigned['User'] = assign_users
          report = Report.new(assigned: assigned, unassigned: unassigned_counts, foreign_links: foreign_links)
          raise ActiveRecord::Rollback if @dry_run
        end
        report
      end
    end

    private

    def connection
      CodebaseImportMapping.connection
    end

    def assign_by_record(model)
      connection.exec_update(sanitize(<<~SQL.squish, model.name))
        UPDATE codebase_import_mappings AS m
        SET organisation_id = r.organisation_id, updated_at = NOW()
        FROM #{model.quoted_table_name} AS r
        WHERE m.organisation_id IS NULL AND m.entity_type = ? AND m.local_id = r.id
      SQL
    end

    def assign_users
      connection.exec_update(<<~SQL.squish)
        UPDATE codebase_import_mappings AS m
        SET organisation_id = candidates.organisation_id, updated_at = NOW()
        FROM (
          SELECT mb.user_id, MIN(mb.organisation_id::text)::uuid AS organisation_id
          FROM memberships AS mb
          WHERE EXISTS (SELECT 1 FROM codebase_import_files AS f WHERE f.organisation_id = mb.organisation_id)
          GROUP BY mb.user_id
          HAVING COUNT(DISTINCT mb.organisation_id) = 1
        ) AS candidates
        WHERE m.organisation_id IS NULL AND m.entity_type = 'User' AND m.local_id = candidates.user_id
          AND NOT EXISTS (
            SELECT 1 FROM codebase_import_mappings AS taken
            WHERE taken.organisation_id = candidates.organisation_id
              AND taken.codebase_id = m.codebase_id AND taken.entity_type = 'User'
          )
      SQL
    end

    def unassigned_counts
      CodebaseImportMapping.where(organisation_id: nil).group(:entity_type).count
    end

    # Imported bookings (those with a TimeSession mapping) whose ticket, billing
    # group or creator belongs to another organisation.
    def foreign_links
      imported = "EXISTS (SELECT 1 FROM codebase_import_mappings AS m WHERE m.entity_type = 'TimeSession' AND m.local_id = ts.id)"
      {
        'ticket' => booking_ids(<<~SQL.squish),
          SELECT ts.id FROM time_sessions AS ts JOIN tickets AS t ON t.id = ts.ticket_id
          WHERE t.organisation_id <> ts.organisation_id AND #{imported}
        SQL
        'time_session_group' => booking_ids(<<~SQL.squish),
          SELECT ts.id FROM time_sessions AS ts JOIN time_session_groups AS g ON g.id = ts.time_session_group_id
          WHERE g.organisation_id <> ts.organisation_id AND #{imported}
        SQL
        'creator' => booking_ids(<<~SQL.squish)
          SELECT ts.id FROM time_sessions AS ts
          WHERE #{imported} AND NOT EXISTS (
            SELECT 1 FROM memberships AS mb WHERE mb.user_id = ts.creator_id AND mb.organisation_id = ts.organisation_id
          )
        SQL
      }
    end

    def booking_ids(sql)
      connection.select_values(sql)
    end

    def sanitize(sql, *values)
      CodebaseImportMapping.sanitize_sql_array([sql, *values])
    end
  end
end
