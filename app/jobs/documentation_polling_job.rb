# frozen_string_literal: true

# Slice-2 auto-sync, polling variant (design decision: polling first, webhooks
# as a separately switchable later step). Runs on the Solid Queue recurring
# schedule (config/recurring.yml) and fans out one DocumentationSyncJob per set.
#
# Deliberately dumb: no per-set staleness or status filtering. The sync job is
# cheap when nothing changed (git-blob-SHA skip), its per-set advisory lock
# already deduplicates overlapping runs, and skipping rows by sync_status would
# permanently starve a set whose worker died mid-run with a stale 'syncing'.
class DocumentationPollingJob < ApplicationJob
  queue_as :default

  def perform
    # Cross-tenant iteration is correct here: this is an operator-level
    # scheduler (like ScheduledDeletionJob), not user-facing code. Each sync
    # job re-establishes its own tenant from the set.
    set_ids = ActsAsTenant.without_tenant { DocumentationSet.pluck(:id) }

    set_ids.each do |set_id|
      DocumentationSyncJob.perform_later(set_id, trigger: 'polling')
    end
  end
end
