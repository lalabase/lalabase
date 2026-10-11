# frozen_string_literal: true

module Embeddings
  # Operator task backing the ada-002 → text-embedding-3-small system-default
  # rollout (S1 of the KI-Kontingent initiative). Two idempotent concerns:
  #
  #   1. Provenance hygiene — an org whose embedding_model was MATERIALISED to the
  #      legacy ada-002 literal (and which otherwise follows the system default) is
  #      reset to nil. nil means "follow the system default", which is now 3-small.
  #      Most orgs already carry nil here (the column has no DB default), so this is
  #      usually a no-op; it only catches an org where an operator once pinned the
  #      old default explicitly. Note the openai provider reads
  #      OpenAiProvider::DEFAULT_EMBEDDING_MODEL, not this column — so this is a
  #      label fix, not a behaviour switch.
  #
  #   2. Re-index — each such org's corpus (currently ada-002 vectors, an
  #      incompatible vector space) is recomputed with 3-small and re-stamped via
  #      OrganisationReindexer. THIS is the operative step; the dimension stays
  #      1536 so the schema/indexes are untouched.
  #
  # Untouched by design:
  #   * BYOK embedding orgs (own embedding_access_token) — their sovereign
  #     endpoint/model is their choice.
  #   * Orgs on a different provider (openai_compatible) or a non-legacy pinned
  #     model — deliberately configured, not on the system default.
  #
  # Idempotent: a second run normalises nothing (models already nil) and re-embeds
  # nothing (rows already stamped 3-small — OrganisationReindexer skips them).
  class DefaultModelMigrator
    # The model we are migrating AWAY from. Kept as a local literal (not the
    # provider constant, which now points at the new default) so the selection
    # keeps matching legacy rows after the flip.
    LEGACY_DEFAULT_MODEL = 'text-embedding-ada-002'

    OrgResult = Struct.new(:organisation_id, :normalised, :reindex, keyword_init: true)
    Summary = Struct.new(:migrated, :skipped, :results, keyword_init: true)

    def initialize(reindex: true, logger: Rails.logger)
      @reindex = reindex
      @logger = logger
    end

    # @return [Summary]
    def call
      candidates = system_default_organisations
      results = candidates.map { |org| migrate(org) }
      skipped = Organisation.count - candidates.size
      Summary.new(migrated: results.size, skipped: skipped, results: results).tap do |summary|
        @logger.info("[embeddings:migrate_default_model] migrated=#{summary.migrated} " \
                     "skipped(byok/divergent)=#{summary.skipped} reindex=#{@reindex}")
      end
    end

    private

    # Filtered in Ruby (not SQL) on purpose: embedding_access_token is encrypted
    # non-deterministically, so it cannot be matched by value in a WHERE clause.
    # The org count is tiny (one row per tenant), so decrypting to check presence
    # is cheap.
    def system_default_organisations
      Organisation.all.select { |org| system_default?(org) }
    end

    def system_default?(org)
      return false if org.embedding_access_token.present? # BYOK → keep
      # Divergent provider (openai_compatible) → keep.
      return false unless org.embedding_provider.blank? || org.embedding_provider == ::AiCredential::PROVIDER_OPENAI

      # A model pinned to something other than the legacy default → keep.
      org.embedding_model.blank? || org.embedding_model == LEGACY_DEFAULT_MODEL
    end

    def migrate(org)
      OrgResult.new(
        organisation_id: org.id,
        normalised: normalise_model(org),
        reindex: (@reindex ? reindex(org) : nil)
      )
    end

    # Legacy materialised ada-002 → nil (follow system default). Returns whether a
    # write happened (false for the common already-nil case). update_columns: a
    # pure provenance relabel, no validations/callbacks wanted.
    def normalise_model(org)
      return false unless org.embedding_model == LEGACY_DEFAULT_MODEL

      org.update_columns(embedding_model: nil, updated_at: Time.current)
      @logger.info("[embeddings:migrate_default_model] org=#{org.id} embedding_model ada-002 → nil (follow default)")
      true
    end

    # Re-embed the org's corpus. AI-disabled or credential-less orgs have nothing
    # to send anyway — skip them (log) instead of aborting the whole run.
    def reindex(org)
      # metered: false — this is OUR rollout, not the customer's choice (file
      # header: "Operator task backing the ada-002 → text-embedding-3-small
      # rollout"). Billing their monthly quota for a migration they never asked for
      # would also risk pushing them through the quota gate, i.e. breaking their
      # chat and search as a side effect of an operator repair.
      OrganisationReindexer.call(organisation: org, metered: false, logger: @logger)
    rescue Lalabase::Llm::Provider::Error => e
      @logger.warn("[embeddings:migrate_default_model] org=#{org.id} reindex skipped: #{e.class} #{e.message}")
      nil
    end
  end
end
