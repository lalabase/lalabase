# frozen_string_literal: true

# Policy for AI sync status and embedding reprocessing
# Only organisation admins have access
class AiSyncStatusPolicy < ApplicationPolicy
  def show?
    account_admin?
  end

  def reprocess_embeddings?
    account_admin?
  end
end
