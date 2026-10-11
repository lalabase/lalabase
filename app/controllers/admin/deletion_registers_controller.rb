# frozen_string_literal: true

module Admin
  # The audit answer promised by AVV § 12 Abs. 7 (L3 of doc/loeschverzeichnis_plan.md):
  # "Auf Verlangen erteilt der Auftragsverarbeiter dem Verantwortlichen hieraus
  # Auskunft über die dessen Organisation betreffenden Vorgänge."
  #
  # Read-only. The register is written by a before_destroy hook on
  # ActiveStorage::Attachment and maintained by two nightly jobs; nothing here
  # ever writes to it. There is deliberately no customer-facing view: the
  # contract promises an answer on request, not self-service.
  #
  # Two things this page must show and would be easy to leave out, both named in
  # the contract text since L5: entries whose backup confirmation never arrived,
  # and the date the register started. Without the first the answer looks more
  # complete than it is; without the second it implies that nothing was deleted
  # before that day.
  class DeletionRegistersController < Admin::ApplicationController
    include Pagy::Backend

    ENTRIES_PER_PAGE = 50

    def show
      @started_at = AttachmentDeletionRecord.register_started_at
      @organisations = AttachmentDeletionRecord.organisations_in_register
      @organisation_id = selected_organisation_id

      scope = filtered_scope
      @total = scope.count
      @pending_confirmation = scope.without_backup_confirmation.count
      # Only meaningful unfiltered: with a filter the scope already excludes them.
      @without_organisation = AttachmentDeletionRecord.without_organisation.count if @organisation_id.nil?

      @pagy, @records = pagy(scope.recent_first, limit: ENTRIES_PER_PAGE)
    end

    private

    def filtered_scope
      return AttachmentDeletionRecord.all if @organisation_id.nil?

      AttachmentDeletionRecord.for_organisation(@organisation_id)
    end

    # Accepts the parameter only if it names an organisation that actually
    # appears in the register. That is not decoration: organisation_id is a uuid
    # column, and an unparsable value would reach PostgreSQL and raise instead of
    # returning an empty answer.
    def selected_organisation_id
      requested = params[:organisation_id].presence
      return nil if requested.nil?

      @organisations.any? { |id, _| id == requested } ? requested : nil
    end
  end
end
