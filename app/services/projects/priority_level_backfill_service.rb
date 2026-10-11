# frozen_string_literal: true

module Projects
  # Adds an explicit `level` (1-based) to each option of every `priority` select that has
  # none, derived from the option's CURRENT position. This snapshot-from-position runs once;
  # afterwards `level` is the source of truth and is independent of display order (an admin
  # reordering options does NOT change the bar levels — by design).
  #
  # This is the only PRODUCTION-DATA mutation in the due-date initiative, so it lives in its
  # own reversible, idempotent, deploy-safe rake task (never part of the schema migration /
  # code merge) — a failure here must not be able to block shipping the feature.
  #
  #   - idempotent: definitions that already carry any level are skipped
  #   - race-safe: each definition is updated under a row lock
  #   - deploy-safe: one failing definition is logged and skipped, not raised
  #   - reversible: .revert strips the level keys back out
  class PriorityLevelBackfillService
    Result = Struct.new(:updated, :skipped, :failed, keyword_init: true)

    def self.call
      new.call
    end

    def call
      updated = skipped = failed = 0

      ActsAsTenant.without_tenant do
        TicketAttributeDefinition.where(name: 'priority', field_type: 'select').find_each do |definition|
          definition.with_lock do
            allowed = definition.options&.dig('allowed_values') || []
            if allowed.empty? || allowed.any? { |opt| opt['level'] }
              skipped += 1
              next
            end

            leveled = allowed.each_with_index.map { |opt, i| opt.merge('level' => i + 1) }
            definition.update!(options: (definition.options || {}).merge('allowed_values' => leveled))
            updated += 1
          end
        rescue ActiveRecord::RecordInvalid => e
          failed += 1
          Rails.logger.warn("[PriorityLevelBackfill] definition #{definition.id} (project #{definition.project_id}): #{e.message}")
        end
      end

      Result.new(updated: updated, skipped: skipped, failed: failed)
    end

    # Reversibility: strip `level` back out of priority options. update_column bypasses
    # validation/callbacks (a pure data revert, no re-validation needed).
    def self.revert
      reverted = 0
      ActsAsTenant.without_tenant do
        TicketAttributeDefinition.where(name: 'priority', field_type: 'select').find_each do |definition|
          allowed = definition.options&.dig('allowed_values') || []
          next unless allowed.any? { |opt| opt.key?('level') }

          stripped = allowed.map { |opt| opt.except('level') }
          definition.update_column(:options, (definition.options || {}).merge('allowed_values' => stripped)) # intentional: pure data revert, no re-validation needed
          reverted += 1
        end
      end
      reverted
    end
  end
end
