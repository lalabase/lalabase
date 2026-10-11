# frozen_string_literal: true

module Projects
  # Adds the Backlog status option (is_backlog) to existing projects whose `status`
  # attribute lacks one.
  #
  #   - idempotent: a second run adds nothing
  #   - race-safe: each definition is updated under a row lock (check-then-append
  #     inside the lock, so two concurrent runs cannot duplicate the option)
  #   - order-preserving: the option is appended last (the first option stays the
  #     de-facto default for new tickets)
  #   - non-destructive: a project that already has a 'backlog' value OR an is_backlog
  #     tagged option is left untouched (never retagged, never duplicated)
  #   - deploy-safe: a single definition that fails to save (e.g. a pre-existing option
  #     that violates a newer validation — grandfathered data) is logged and skipped,
  #     NOT raised. This runs in the deploy hook, so one bad project must never abort the
  #     whole deploy; the failure is surfaced via the log and the `failed` count.
  #
  # Tenant-agnostic: TicketAttributeDefinition carries no acts_as_tenant (it is scoped
  # via its project), so a tenant context is not required to enumerate definitions.
  class BacklogStatusBackfillService
    Result = Struct.new(:added, :skipped, :failed, keyword_init: true)

    def self.call
      new.call
    end

    def call
      added = 0
      skipped = 0
      failed = 0

      TicketAttributeDefinition.where(name: 'status', field_type: 'select').find_each do |definition|
        definition.with_lock do
          if backlog_present?(definition)
            skipped += 1
            next
          end

          options = definition.options || {}
          allowed = (options['allowed_values'] || []) + [DefaultAttributeService::BACKLOG_STATUS_OPTION.deep_dup]
          definition.update!(options: options.merge('allowed_values' => allowed))
          added += 1
        end
      rescue ActiveRecord::RecordInvalid => e
        # Grandfathered data: a pre-existing option fails a current validation. Don't let
        # it abort the run/deploy — record and continue so every healthy project is still
        # backfilled. The flagged definition can be fixed by hand afterwards.
        failed += 1
        Rails.logger.warn(
          "[BacklogStatusBackfill] skipped definition #{definition.id} " \
          "(project #{definition.project_id}): #{e.message}"
        )
      end

      Result.new(added: added, skipped: skipped, failed: failed)
    end

    private

    # "Present" if EITHER an is_backlog-tagged option exists OR a literal value 'backlog'
    # exists. The value-based check is deliberate: a project that already uses 'backlog'
    # as a (possibly untagged) status keeps its own option — we never retag or duplicate
    # user data. Accepted consequence: such a project does not gain is_backlog semantics
    # from this backfill; the owner can tag it by hand if they want the active-work filter.
    def backlog_present?(definition)
      (definition.options&.dig('allowed_values') || []).any? do |opt|
        opt['value'].to_s.casecmp?('backlog') ||
          (opt['system_functions'] || []).include?(SystemFunctions::Registry::IS_BACKLOG)
      end
    end
  end
end
