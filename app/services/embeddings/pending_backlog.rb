# frozen_string_literal: true

module Embeddings
  # System-wide discovery of organisations that still have content waiting to be
  # embedded (embeddings_creation_flag not yet true), OLDEST backlog first. Used by
  # the monthly quota-reset catch-up (AiQuotaMonthlyResumeJob, decision 5A/D13) so
  # orgs that have been paused the longest are served first when budget returns.
  #
  # Runs without a tenant (system job) — this is a legitimate cross-org admin/system
  # read, not a user-facing one. The "what is pending" rules come from the shared
  # Embeddings::PendingEmbeddings (same source EmbeddingReprocessingService enqueues
  # from); here they run without_tenant, so they span all orgs and we group by org.
  module PendingBacklog
    module_function

    # @return [Array<String>] organisation ids, oldest pending record first.
    def organisation_ids_oldest_first
      ActsAsTenant.without_tenant do
        earliest = {}
        Embeddings::PendingEmbeddings.relations.each do |relation|
          relation.group(:organisation_id).minimum(:created_at).each do |org_id, timestamp|
            next if org_id.nil?

            current = earliest[org_id]
            earliest[org_id] = [current, timestamp].compact.min
          end
        end
        earliest.sort_by { |_org_id, timestamp| timestamp }.map(&:first)
      end
    end
  end
end
