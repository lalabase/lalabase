# frozen_string_literal: true

module Admin
  # Assessed contract versions of a provider
  # (doc/ki_vertragsdaten_plan.md § 5/T4). The version is a commitment
  # to customers: it comes only from a human assessment, never from
  # a machine evaluation of the document text (D2).
  class AiCredentialContractsController < Admin::ApplicationController
    before_action :set_credential

    def create
      result = Actors::RecordCredentialContract.call(
        credential: @credential, attributes: contract_params,
        document_ids: params[:ai_credential_contract]&.fetch(:document_ids, []),
        recorded_by_email: current_user&.email
      )

      if result.success?
        redirect_to admin_ai_credential_path(@credential),
                    notice: t('flash.admin.ai_credential_contracts.created')
      else
        redirect_to admin_ai_credential_path(@credential), alert: result.errors.join(' ')
      end
    end

    # As with the account discount: a running version can only be ENDED, not
    # changed. A silently rewritten assessment destroys exactly the
    # traceability that the separate table exists for.
    def update
      contract = @credential.contracts.find(params[:id])
      new_end = parsed_end_date

      return redirect_with_alert(t('flash.admin.ai_credential_contracts.end_date_invalid')) if new_end.nil?
      return redirect_with_alert(t('flash.admin.ai_credential_contracts.end_date_not_earlier')) unless
        endable?(contract, new_end)

      contract.update!(ends_on: new_end)
      redirect_to admin_ai_credential_path(@credential),
                  notice: t('flash.admin.ai_credential_contracts.ended')
    end

    private

    def set_credential
      @credential = ::AiCredential.find(params[:ai_credential_id])
    end

    def contract_params
      params.require(:ai_credential_contract)
            .permit(:training_usage, :retention_policy, :retention_days,
                    :subprocessors_disclosure, :subprocessors, :note, :starts_on)
    end

    def parsed_end_date
      Date.parse(params.require(:ai_credential_contract)[:ends_on].to_s)
    rescue Date::Error, TypeError
      nil
    end

    # The lower bound is the version's own start, not today: for an announced
    # version, an earlier date would otherwise reach update! and turn a
    # form error into a 500.
    def endable?(contract, new_end)
      return false if new_end < [contract.starts_on, Date.current].max
      return true if contract.ends_on.nil?

      new_end <= contract.ends_on
    end

    def redirect_with_alert(message)
      redirect_to admin_ai_credential_path(@credential), alert: message
    end
  end
end
