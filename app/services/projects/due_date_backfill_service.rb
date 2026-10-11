# frozen_string_literal: true

module Projects
  # Provisions the default `due_date` date field into existing projects that lack it,
  # reusing DefaultAttributeService.ensure_due_date (reconciliation-aware: a pre-existing
  # NON-date `due_date` is logged and skipped, never overwritten). Idempotent and
  # deploy-safe — one bad project is recorded, not raised, so it cannot abort a deploy.
  #
  # Runs WITHOUT a tenant (spans all organisations); without_tenant lifts require_tenant
  # thread-locally so enumerating/loading Project does not raise.
  class DueDateBackfillService
    Result = Struct.new(:created, :existed, :conflicts, :failed, keyword_init: true)

    def self.call
      new.call
    end

    def call
      created = existed = conflicts = failed = 0

      ActsAsTenant.without_tenant do
        Project.find_each do |project|
          case DefaultAttributeService.ensure_due_date(project)
          when :created then created += 1
          when :exists then existed += 1
          when :conflict then conflicts += 1
          end
        rescue ActiveRecord::RecordInvalid => e
          failed += 1
          Rails.logger.warn("[DueDateBackfill] project #{project.id}: #{e.message}")
        end
      end

      Result.new(created: created, existed: existed, conflicts: conflicts, failed: failed)
    end

    # Reversibility: remove the auto-provisioned (system) due_date fields. Tickets keep
    # their stored custom_attributes['due_date'] values — only the definition is removed.
    def self.revert
      removed = 0
      ActsAsTenant.without_tenant do
        TicketAttributeDefinition.where(name: Ticket::DUE_DATE_KEY, field_type: 'date', system: true).find_each do |definition|
          definition.destroy!
          removed += 1
        end
      end
      removed
    end
  end
end
