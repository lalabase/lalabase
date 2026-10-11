# frozen_string_literal: true

# Embedding v2 PR 6a — find-or-create the embedding_spaces row for an org's
# CONFIGURED triple (details on the class).
module Embeddings
  # Finds or creates the embedding_spaces row for an organisation's CONFIGURED vector
  # space and refreshes its credential snapshot
  # (doc/embedding_v2_pr6_retention_plan.md §4.3).
  #
  # Token rotation to the SAME triple REFRESHES the row — it does not create a second
  # space. A rotated token does not make the stored vectors incompatible, and the
  # unique index is on the triple, so "new credentials" and "new space" are genuinely
  # different events.
  #
  # The triple comes from Factory.embedding_space_for(space: :configured), NOT from the
  # org's raw columns: only the resolved form carries the normalisation the write paths
  # stamp (provider ROUTING KEY rather than display name, the provider's effective
  # model rather than nil, the clamped dimension). A row built from raw columns would
  # key a space that no sidecar row ever lands in.
  #
  # Since P0 (doc/ki_pakete_plan.md §7b.2) the refresh also writes the ai_credential_id
  # pin — the id of the resolved system credential on the system path, nil on the BYOK
  # path — so the row addresses ONE credential instead of whichever one currently holds
  # the provider's active slot.
  #
  # That pin is written ONCE and then belongs to the row: see #pin_for. Refreshing it
  # like the other snapshot columns would defeat its own purpose.
  #
  # Deliberately NOT called from the write paths — there it would be one write per
  # embed call. Its callers are the build task and the space backfill.
  #
  # Entry point: call
  class EnsureSpace
    # @return [EmbeddingSpace] the persisted row for the configured triple
    def self.call(organisation:)
      new(organisation: organisation).call
    end

    def initialize(organisation:)
      @organisation = organisation
    end

    def call
      triple = ::Lalabase::Llm::Factory.embedding_space_for(@organisation, space: :configured)
      credentials = ::Lalabase::Llm::Factory.embedding_credentials_for(@organisation)

      ActsAsTenant.with_tenant(@organisation) do
        space = ::EmbeddingSpace.find_or_initialize_by(organisation_id: @organisation.id, **triple)
        # update! even for an existing row: this IS the credential refresh. Writing nils
        # on the system path is intended — it restores "resolve the system credential"
        # for a space whose org has since dropped its BYOK setup.
        space.update!(**credentials.merge(ai_credential_id: pin_for(space, credentials)))
        space
      end
    end

    private

    # The ONE snapshot column that is not refreshed. Everything else here may be
    # rewritten on every call; re-resolving the pin would hand a HELD space to whichever
    # credential owns the provider's default slot today — the exact swap the column
    # exists to prevent, only reached through the refresh path instead of the read path.
    # Two same-provider system credentials advertising the same default_model (Mistral FR
    # next to IONOS DE, both openai_compatible/bge-1536) share a triple, so `flip` and
    # `build_target` find the pinned row and would silently repoint it.
    #
    # Two cases still write:
    #   * no pin yet — legacy rows and first contact, this is where the pin is born.
    #   * the row went BYOK — its own token serves it from here on, and the read path
    #     (Factory#descriptor_from_space, same access_token.present? test) never consults
    #     a pin again. Leaving one would name a credential nothing reads.
    # A pin that diverges from today's default is a legitimate state, not a fault, but it
    # is worth saying out loud once per refresh — moving a space to another credential is
    # an explicit act (P1 admin CRUD), never a side effect of a reindex.
    def pin_for(space, credentials)
      return nil if credentials[:access_token].present?

      resolved_id = credentials[:ai_credential_id]
      return resolved_id if space.ai_credential_id.blank?
      return space.ai_credential_id if resolved_id.blank? || resolved_id == space.ai_credential_id

      Rails.logger.warn(
        "Embeddings::EnsureSpace: embedding space #{space.id} stays pinned to credential " \
        "#{space.ai_credential_id}; the #{space.embedding_provider} default is now #{resolved_id}. " \
        'Repoint the space explicitly if it is meant to move.'
      )
      space.ai_credential_id
    end
  end
end
