# frozen_string_literal: true

# Monthly quota-reset catch-up (decision 5A/D13, config/recurring.yml). After the
# calendar month rolls over, every org's budget is fresh again — so re-drive the
# embeddings that were paused while the quota was exhausted, OLDEST backlog first
# (fairness when many orgs reset at once).
#
# Each org's resume is a separate AiQuotaResumeJob whose backfill is quota-aware:
# an org whose fresh budget is still too small for its backlog embeds what it can
# and leaves the rest pending (no endless loop, plan §13 / test 18).
class AiQuotaMonthlyResumeJob < ApplicationJob
  queue_as :default

  def perform
    ids = Embeddings::PendingBacklog.organisation_ids_oldest_first
    # ONE load, then iterate in the oldest-first order (no per-id N+1).
    organisations_by_id = Organisation.where(id: ids).index_by(&:id)
    ids.each do |organisation_id|
      organisation = organisations_by_id[organisation_id]
      next unless organisation&.ai_enabled?

      AiQuotaResumeJob.perform_later(organisation)
    end
  end
end
