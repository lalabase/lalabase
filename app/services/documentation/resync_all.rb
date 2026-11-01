# frozen_string_literal: true

# Enqueues a full sync of every documentation set of every organisation.
#
# For the day the RENDERER changes: the HTML of a page is a cache written at sync time,
# and a poll skips every set whose repository did not move. Without this step a page
# keeps what the older code wrote, until somebody commits to its repository. A MANUAL
# sync always runs in full, so that is what this asks for.
#
# Run once after the deploy that needs it: `bin/rails documentation:resync_all`.
module Documentation
  class ResyncAll
    def self.call = new.call

    # @return [Integer] the number of sets a sync was enqueued for
    def call
      # Across all tenants on purpose: this is an operator's step, outside any request.
      ids = ActsAsTenant.without_tenant { DocumentationSet.order(:created_at).pluck(:id) }
      ids.each { |id| DocumentationSyncJob.perform_later(id, trigger: 'manual') }
      ids.size
    end
  end
end
