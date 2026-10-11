# frozen_string_literal: true

module Admin
  # Contract documents of a provider (doc/ki_vertragsdaten_plan.md § 4/T3).
  # A record is ONE version of a paper: a revised Google SST is a new entry,
  # not a change to the old one. Only this way can a commitment made in March
  # be traced back to the paper it was based on.
  #
  # Authorization comes from Admin::ApplicationController (Beuser session), NOT
  # from Pundit. A trivial single write with an attachment, so no Actor. The
  # switch of version is the non-trivial part and lives in the other controller.
  class AiCredentialDocumentsController < Admin::ApplicationController
    before_action :set_credential

    def create
      # ai_credential_id comes from the nested route: building THROUGH the
      # association sets the foreign key after the attributes and so wins
      # against a value smuggled in the body.
      document = @credential.documents.new(document_params)
      document.added_by_email = current_user&.email

      write_guarded(document, notice_key: 'created') { document.save }
    end

    # Correct descriptive details. NO contradiction to the immutability of the
    # assessments: that applies to the STATEMENT that already stood on a
    # customer card. A document is the EVIDENCE (a pointer to someone else's
    # paper), and correcting a mistyped "gültig ab" restores the truth instead
    # of bending it. The plan asks for immutability explicitly only for the
    # version (§ 5/D2), never for the document.
    #
    # Without this path a wrong entry was final: deletion is blocked by
    # restrict_with_error as soon as the document backs a version, and adding
    # a corrected row even sorts the wrong one BEFORE the right one because of
    # `newest_first`.
    def update
      document = @credential.documents.find(params[:id])

      write_guarded(document, notice_key: 'updated') do
        next false unless document.update(document_params)

        # ONLY after validation passed. The other way round, a rejected
        # correction (empty title, colliding date) would still have destroyed
        # the PDF, and the notice next to it would not have said so.
        document.file.purge if remove_file?
        true
      end
    end

    # A document that backs a version is exactly the evidence this feature is
    # built for. The model refuses the deletion (restrict_with_error), here it
    # is only reported in a readable way.
    def destroy
      document = @credential.documents.find(params[:id])

      if document.destroy
        back_to_credential(notice: t('flash.admin.ai_credential_documents.deleted'))
      else
        back_to_credential(alert: t('flash.admin.ai_credential_documents.delete_blocked'))
      end
    end

    private

    def set_credential
      @credential = ::AiCredential.find(params[:ai_credential_id])
    end

    # Both write paths have the same two failures, which end uncaught as a 500
    # instead of a readable notice. That is why they are handled here once
    # instead of twice:
    #
    #   * RecordNotUnique: the uniqueness validation reads, the index writes.
    #     Two concurrent writes both get past the check and only collide at
    #     commit on `idx_credential_documents_unique_version`.
    #   * InvalidSignature: ActiveStorage reads a string in the `file` field as
    #     a signed blob ID. The strip in `document_params` only catches "", any
    #     other string blows up on assignment.
    def write_guarded(document, notice_key:)
      if yield
        back_to_credential(notice: t("flash.admin.ai_credential_documents.#{notice_key}"))
      else
        back_to_credential(alert: document.errors.full_messages.join(' '))
      end
    rescue ActiveRecord::RecordNotUnique
      back_to_credential(alert: t('flash.admin.ai_credential_documents.version_conflict'))
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      back_to_credential(alert: t('flash.admin.ai_credential_documents.file_unreadable'))
    end

    def back_to_credential(**flash_options)
      redirect_to admin_ai_credential_path(@credential), **flash_options
    end

    # Separate from the form scope because it is not an attribute: a checkbox
    # that triggers an action, not a field that carries a value.
    def remove_file?
      params[:remove_file] == '1'
    end

    def document_params
      permitted = params.require(:ai_credential_document)
                        .permit(:document_key, :title, :summary, :url, :locator, :body,
                                :valid_from, :file)
      # An empty file field sends "", and the has_one_attached writer reads ""
      # as REMOVE (ActiveStorage::Attached::Changes::DeleteOne). Without this
      # strip, every correction to the source reference would throw away the
      # PDF already uploaded, without anything failing.
      #
      # The price: "empty" can no longer mean "remove". Removing therefore goes
      # through its own checkbox (`remove_file?`). Otherwise an accidentally
      # attached PDF would be just as final as a wrong date was before this
      # slice.
      permitted.delete(:file) if permitted[:file].blank?
      permitted
    end
  end
end
