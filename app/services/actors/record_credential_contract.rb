# frozen_string_literal: true

module Actors
  # Records a new assessed contract version
  # (doc/ki_vertragsdaten_plan.md § 5/T4). Non-trivial by the seam rule:
  # close the running version, create the new one and link the supporting
  # documents. Three writes that hold together or not at all.
  #
  # THE ORDER IS LOAD-BEARING, as in Actors::PublishPriceList: the predecessor
  # is clipped BEFORE the new version is created. The other way round, the
  # overlap rule of EffectiveDating rejects our own write.
  #
  # NO current_user: the operator in the admin area is a Beuser, not a User,
  # and Current.user feeds the activity chain, which expects a real User. The
  # evidence is the email snapshot on the row.
  class RecordCredentialContract < BaseActor
    def initialize(credential:, attributes:, document_ids: [], recorded_by_email: nil)
      super()
      @credential = credential
      @attributes = attributes.to_h.symbolize_keys
      @document_ids = Array(document_ids).reject(&:blank?)
      @recorded_by_email = recorded_by_email
    end

    def perform
      reject_past_start!
      close_running_version!
      create_version!
      link_documents!
    end

    def record
      @contract
    end

    private

    # An assessment applies from today or later. Assessing retroactively would
    # mean changing a statement that already stood on a customer card, which is
    # exactly what the versioning is meant to prevent.
    def reject_past_start!
      return if starts_on.present? && starts_on >= Date.current

      raise ActorError.new(I18n.t('services.actors.record_credential_contract.starts_on_in_past'),
                           code: :starts_on_in_past)
    end

    def close_running_version!
      running = @credential.contract_on(starts_on)
      return if running.nil?
      return if running.ends_on.present? && running.ends_on < starts_on

      running.update!(ends_on: starts_on - 1.day)
    end

    def create_version!
      @contract = @credential.contracts.create!(
        **@attributes.slice(:training_usage, :retention_policy, :retention_days,
                            :subprocessors_disclosure, :subprocessors, :note),
        starts_on: starts_on, recorded_by_email: @recorded_by_email
      )
    end

    # Only documents of THIS credential. The selection list shows only these
    # anyway, and a smuggled-in foreign key would back a version with another
    # provider's paperwork.
    def link_documents!
      return if @document_ids.empty?

      @credential.documents.where(id: @document_ids).find_each do |document|
        @contract.contract_documents.create!(ai_credential_document: document)
      end
    end

    def starts_on
      @starts_on ||= begin
        Date.parse(@attributes[:starts_on].to_s)
      rescue Date::Error, TypeError
        nil
      end
    end
  end
end
