# frozen_string_literal: true

# app/services/actors/destroy_document_version.rb
#
# Destroys ONE version of a document. Three outcomes:
#   1. the version is not the current one            -> just destroy it
#   2. the version is current, other versions exist  -> promote the next-newest
#      (created_at desc) to current_version, then destroy the old one
#   3. the version is the last remaining one         -> destroy the whole document
#
# The caller picks its redirect from #document_destroyed? (outcome 3 vs 1/2) and
# reads #record after #call (the surviving document, or nil once the whole
# document is gone). The version is resolved INSIDE document.document_versions, so
# a missing/foreign version_id becomes a :not_found failure (Redirect + Alert),
# not a 404. The document object comes in pre-loaded and authorised from the
# controller (set_document + authorize), so there is no second, unscoped lookup.

module Actors
  class DestroyDocumentVersion < BaseActor
    def initialize(document:, version_id:, current_user:)
      super()
      @document = document
      @version_id = version_id
      @current_user = current_user
      @document_destroyed = false
    end

    # The document while it survives; nil once the whole document was destroyed
    # (outcome 3).
    def record
      @document_destroyed ? nil : @document
    end

    def document_destroyed?
      @document_destroyed
    end

    def perform
      version = @document.document_versions.find_by(id: @version_id)
      raise ActorError.new(I18n.t('services.actors.destroy_document_version.not_found'), code: :not_found) if version.nil?

      if @document.current_version == version
        next_version = @document.document_versions.where.not(id: version.id).order(created_at: :desc).first

        if next_version
          @document.update!(current_version: next_version)
        else
          # Last version: break the current_version FK, drop the version, then
          # drop the now-empty document.
          @document.update!(current_version: nil)
          version.destroy!
          @document.destroy!
          @document_destroyed = true
          return
        end
      end

      version.destroy!
    end
  end
end
