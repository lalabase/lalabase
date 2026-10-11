# frozen_string_literal: true

# app/services/actors/destroy_document.rb
#
# Destroys a Document together with all of its versions. current_version is
# nulled first to break the documents.current_version_id FK, then every version
# is destroyed individually (find_each(&:destroy!)) so its callbacks run —
# Fragment cleanup (embeddings) and the ActiveStorage attachment purge. A
# delete_all shortcut would orphan blobs and fragments, so it is deliberately
# avoided. The whole sequence runs in one transaction (BaseActor#call), so any
# failure rolls the entire delete back.

module Actors
  class DestroyDocument < BaseActor
    def initialize(document:, current_user:)
      super()
      @document = document
      @current_user = current_user
    end

    # A destroy leaves no surviving primary record.
    def record
      nil
    end

    def perform
      @document.update!(current_version: nil)
      # One destroy per version so its callbacks run — Fragment cleanup and the
      # ActiveStorage attachment purge. Deliberately NOT batched (no delete_all,
      # no DestroyPost-style purge batch): a document has few versions and the
      # per-version callbacks are the point (D4). The bounded per-version purge
      # fanout at commit is not a request N+1.
      @document.document_versions.find_each(&:destroy!)
      @document.destroy!
    end
  end
end
