# frozen_string_literal: true

require 'rails_helper'

# What this file protects (embedding v2 PR 6a)
# --------------------------------------------
# The `space:` seam in Lalabase::Llm::Factory, i.e. the separation of CONFIGURATION
# (where new embeddings go) from SERVING (which space answers queries):
#
#   * :configured / :active resolve DIFFERENT spaces during a staged switch,
#   * `space:` is mandatory — the loud failure that replaces two silent ones,
#   * review blocker B2: a BYOK org can serve AND roll back an old space from that
#     space's own credential snapshot, after its single-valued embedding_* columns have
#     long been overwritten,
#   * the pointer read does not depend on the ambient tenant (require_tenant = true
#     would otherwise turn a foreign tenant into a silent fallback to the config).
RSpec.describe Lalabase::Llm::Factory do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  describe 'space: is mandatory' do
    it 'raises without the kwarg rather than guessing a space' do
      expect { described_class.for_embeddings(organisation) }.to raise_error(ArgumentError)
      expect { described_class.embedding_space_for(organisation) }.to raise_error(ArgumentError)
    end

    it 'raises on an unknown space name' do
      expect { described_class.embedding_space_for(organisation, space: :whatever) }
        .to raise_error(ArgumentError, /Unknown embedding space/)
    end
  end

  describe 'configured vs. active during a staged switch' do
    let!(:credential) do
      create(:ai_credential, :active, :embedding_only, provider: 'openai', access_token: 'sk-system')
    end
    let!(:old_space) do
      create(:embedding_space, organisation: organisation, embedding_provider: 'openai',
                               embedding_model: 'text-embedding-ada-002', embedding_dims: 1536)
    end

    before do
      organisation.update!(active_embedding_space_id: old_space.id, embedding_dims: 1024)
    end

    it 'serves the OLD space while the configuration already names the new one' do
      expect(described_class.embedding_space_for(organisation, space: :active))
        .to eq(embedding_provider: 'openai', embedding_model: 'text-embedding-ada-002',
               embedding_dims: 1536)
      expect(described_class.embedding_space_for(organisation, space: :configured))
        .to include(embedding_dims: 1024)
    end

    it 'builds an :active provider whose expected dimension is the SPACE dimension' do
      provider = described_class.for_embeddings(organisation, space: :active)

      expect(provider.expected_embedding_dims).to eq(1536)
    end

    it 'builds a :configured provider whose expected dimension is the CONFIGURED one' do
      provider = described_class.for_embeddings(organisation, space: :configured)

      expect(provider.expected_embedding_dims).to eq(1024)
    end

    # Without a pointer there is nothing to follow: :active falls back to the effective
    # configuration (series plan §5.3) — the fresh-org case.
    it 'falls back to the configured space when no pointer is set' do
      organisation.update!(active_embedding_space_id: nil)

      expect(described_class.embedding_space_for(organisation, space: :active))
        .to eq(described_class.embedding_space_for(organisation, space: :configured))
    end

    # The gate-freedom pinned since PR 4b must survive the repoint: this read feeds a
    # LOCAL sidecar query, so it must keep working while the quota is exhausted.
    it 'still resolves the active space when the quota gate would raise' do
      allow(Lalabase::Llm::Gate).to receive(:ensure_within_quota!)
        .and_raise(Lalabase::Llm::QuotaExceededError, 'exhausted')

      expect(described_class.embedding_space_for(organisation, space: :active))
        .to include(embedding_model: 'text-embedding-ada-002')
    end

    it 'still resolves the active space for an org with AI switched off' do
      organisation.update!(ai_enabled: false)

      expect { described_class.embedding_space_for(organisation, space: :active) }.not_to raise_error
    end
  end

  # [B2] The headline case: a BYOK org switches endpoints. Its embedding_* columns are
  # single-valued, so after the switch they no longer describe the space that is still
  # serving — and a roll-back would need credentials nobody has any more. The snapshot
  # is what keeps both possible.
  describe 'BYOK credential snapshot (B2)' do
    let!(:old_space) do
      create(:embedding_space, :byok, organisation: organisation, embedding_model: 'bge-1536',
                                      api_base: 'https://old.example.test/v1',
                                      access_token: 'sk-OLD-endpoint')
    end

    before do
      organisation.update!(active_embedding_space_id: old_space.id,
                           # The columns now describe the NEW endpoint — the old values are GONE.
                           embedding_provider: 'openai_compatible',
                           embedding_model: 'new-model',
                           embedding_api_base: 'https://new.example.test/v1',
                           embedding_access_token: 'sk-NEW-endpoint')
    end

    it 'serves the old space with the OLD credentials, not the overwritten columns' do
      provider = described_class.for_embeddings(organisation, space: :active)

      expect(provider.api_key).to eq('sk-OLD-endpoint')
      expect(provider.api_base).to eq('https://old.example.test/v1')
    end

    it 'builds the configured space with the NEW credentials (the two do not bleed)' do
      provider = described_class.for_embeddings(organisation, space: :configured)

      expect(provider.api_key).to eq('sk-NEW-endpoint')
      expect(provider.api_base).to eq('https://new.example.test/v1')
    end

    # The roll-back path: a space that is NEITHER active nor configured must still be
    # reachable through its own snapshot — this is what a delta reindex of an old space
    # runs on.
    # [R4, review 2026-08-01] Cross-tenant guard. Unreachable through today's only
    # caller (the rollback task filters by organisation_id), but this method becomes
    # reachable from the 6b admin UI, and a BYOK credential crossing a tenant boundary
    # must fail loudly rather than rely on a caller's diligence.
    it 'refuses a space belonging to another organisation' do
      other = create(:organisation, name: 'Foreign', subdomain: 'foreign-space')
      foreign = ActsAsTenant.with_tenant(other) do
        create(:embedding_space, :byok, organisation: other, access_token: 'sk-FOREIGN')
      end

      expect { described_class.for_embedding_space(foreign, organisation) }
        .to raise_error(Lalabase::Llm::Provider::Error, /does not belong to organisation/)
    end

    it 'builds a provider for any held space from that space own snapshot' do
      other = create(:embedding_space, :byok, organisation: organisation, embedding_model: 'third',
                                              api_base: 'https://third.example.test/v1',
                                              access_token: 'sk-THIRD')

      provider = described_class.for_embedding_space(other, organisation)

      expect(provider.api_key).to eq('sk-THIRD')
      expect(provider.api_base).to eq('https://third.example.test/v1')
    end

    # NULL credentials mean "resolve the system credential", NOT "no credentials" —
    # copying the system token into the row would freeze a rotating secret.
    it 'resolves the system credential for a space with a nil snapshot' do
      create(:ai_credential, :active, :embedding_only, provider: 'openai', access_token: 'sk-system')
      system_space = create(:embedding_space, organisation: organisation, embedding_provider: 'openai',
                                              embedding_model: 'text-embedding-3-small')

      provider = described_class.for_embedding_space(system_space, organisation)

      expect(provider.api_key).to eq('sk-system')
    end

    it 'carries the snapshot-resolved system credential on the provider (P0 attribution)' do
      credential = create(:ai_credential, :active, :embedding_only, provider: 'openai', access_token: 'sk-system')
      system_space = create(:embedding_space, organisation: organisation, embedding_provider: 'openai',
                                              embedding_model: 'text-embedding-3-small')

      provider = described_class.for_embedding_space(system_space, organisation)

      expect(provider.billing_credential).to eq(credential)
    end

    # P0: the quota gate judges the credential of the space that SERVES the call,
    # not a fresh lookup off the org's CURRENT columns. During a staged switch the
    # two differ: the served space here is BYOK (costs us nothing, must pass), while
    # the configured target bills an exhausted quota credential (must be blocked).
    # Before P0 the gate judged BOTH calls off the current columns.
    it 'gates by the served space credential, not the configured columns' do
      exhausted_org = organisation
      exhausted_org.update!(ai_quota_credits_override: 10, ai_quota_buffer_override: 5,
                            embedding_access_token: nil, embedding_api_base: nil)
      system_credential = create(:ai_credential, :active, provider: 'openai_compatible',
                                                          api_base: 'https://new.example.test/v1',
                                                          default_model: 'new-model', included_in_quota: true)
      AiUsage.create!(organisation: exhausted_org, provider: 'openai_compatible',
                      ai_credential: system_credential, credits_used: 50, used_at: Time.current)

      active_provider = described_class.for_embeddings(exhausted_org, space: :active)
      expect(active_provider.billing_credential).to be_nil # BYOK snapshot row

      expect { described_class.for_embeddings(exhausted_org, space: :configured) }
        .to raise_error(Lalabase::Llm::QuotaExceededError)
    end
  end

  # [P0, doc/ki_pakete_plan.md §7b.2] A space on the SYSTEM path stores no token, so it
  # has to say which system credential serves it. By provider NAME that answer is
  # ambiguous the moment two openai_compatible credentials stand side by side — the
  # normal case for the EU packages (Mistral FR next to IONOS DE): the space built for
  # one of them would be served the OTHER one's key, sent to the right snapshot endpoint
  # with the wrong token, and billed to the wrong credential on top. embedding_spaces.
  # ai_credential_id addresses ONE credential; NULL keeps the legacy name resolution.
  describe 'credential-pinned space resolution (P0)' do
    # Only ONE credential per provider may be active (unique partial index), and the
    # active one is what name resolution finds. So the PIN target is the inactive one:
    # that is precisely the constellation where the two answers differ, and where the
    # name-based lookup used to hand out the wrong key.
    let!(:pinned_credential) do
      create(:ai_credential, :embedding_only, provider: 'openai_compatible', name: 'Pinned (IONOS DE)',
                                              access_token: 'sk-PINNED', default_model: 'bge-1536',
                                              additional_config: { 'uri_base' => 'https://pinned.example.test/v1' })
    end
    let!(:provider_default) do
      create(:ai_credential, :active, :embedding_only, provider: 'openai_compatible',
                                                       name: 'Provider default (Mistral FR)',
                                                       access_token: 'sk-DEFAULT', default_model: 'bge-1536',
                                                       additional_config: { 'uri_base' => 'https://default.example.test/v1' })
    end
    let!(:space) do
      create(:embedding_space, organisation: organisation, embedding_provider: 'openai_compatible',
                               embedding_model: 'bge-1536', embedding_dims: 1536,
                               ai_credential_id: pinned_credential.id)
    end

    it 'serves the PINNED credential, not the provider default' do
      provider = described_class.for_embedding_space(space, organisation)

      expect(provider.api_key).to eq('sk-PINNED')
    end

    # The gate and the usage attribution judge whatever rides on billing_credential —
    # a pin that only reached the api_key would still bill the wrong credential.
    it 'attributes the call to the pinned credential' do
      provider = described_class.for_embedding_space(space, organisation)

      expect(provider.billing_credential).to eq(pinned_credential)
    end

    # Loud, not silent: falling back to the provider default here would restore exactly
    # the swap this column exists to prevent, only now against an operator's explicit
    # assignment.
    it 'raises rather than falling back when the pinned credential is disabled' do
      pinned_credential.update!(enabled: false)

      expect { described_class.for_embedding_space(space, organisation) }
        .to raise_error(Lalabase::Llm::Factory::MissingCredentialError, /refusing to fall back/)
    end

    # The FK rules out a permanently dangling pin, but not a STALE one: a long-running
    # rollback holds the row object while an admin deletes the credential. The DB column
    # is NULL by then, the in-memory id is not — and resolving it against the provider
    # default would be the swap again, in the one situation nobody is watching.
    it 'raises for a stale row whose credential was deleted underneath it' do
      pinned_credential.destroy!

      expect { described_class.for_embedding_space(space, organisation) }
        .to raise_error(Lalabase::Llm::Factory::MissingCredentialError, /missing, disabled or not a/)
    end

    # A pin naming ANOTHER provider is the same swap from the other side: the row's
    # endpoint stays, the secret comes from a provider that never issued it. Unreachable
    # while EnsureSpace is the only writer, but P1 puts this column in an admin form —
    # and the symptom there would be an opaque 401 from a third party, not a fault this
    # app can name.
    it 'raises when the pin names a credential of a different provider' do
      foreign = create(:ai_credential, :embedding_only, provider: 'openai', name: 'Foreign (OpenAI)',
                                                        access_token: 'sk-FOREIGN')
      space.update_column(:ai_credential_id, foreign.id)

      expect { described_class.for_embedding_space(space, organisation) }
        .to raise_error(Lalabase::Llm::Factory::MissingCredentialError, /not a "openai_compatible" credential/)
    end

    # Deleting the credential is the ONE documented way back to name resolution: the FK
    # nullifies the pin, so the row degrades to "the provider's default" instead of
    # becoming permanently unservable. (An inactive credential is deletable —
    # AiCredentialDestroyProtection#ensure_not_last_active only protects the last
    # ACTIVE one.)
    it 'degrades to the provider default when the pinned credential is deleted' do
      pinned_credential.destroy!

      expect(space.reload.ai_credential_id).to be_nil
      expect(described_class.for_embedding_space(space, organisation).api_key).to eq('sk-DEFAULT')
    end

    # Legacy rows (written before the column existed) carry NULL and must keep working
    # exactly as before — the column is deliberately not backfilled.
    it 'resolves an unpinned row by provider name' do
      space.update_column(:ai_credential_id, nil)

      expect(described_class.for_embedding_space(space, organisation).api_key).to eq('sk-DEFAULT')
    end

    # The pin travels through the ACTIVE-space path too, not just the roll-back entry:
    # that is the path every query embedding takes.
    it 'follows the pin when the space is the org active one' do
      organisation.update!(active_embedding_space_id: space.id)

      expect(described_class.for_embeddings(organisation, space: :active).api_key).to eq('sk-PINNED')
    end

    describe '.embedding_credentials_for (what EnsureSpace snapshots)' do
      before do
        organisation.update!(embedding_provider: 'openai_compatible', embedding_model: 'bge-1536')
      end

      it 'pins the resolved system credential without copying its secret' do
        credentials = described_class.embedding_credentials_for(organisation)

        expect(credentials).to eq(api_base: nil, access_token: nil, organization_id: nil,
                                  ai_credential_id: provider_default.id)
      end

      # Defensive, and unreachable through EnsureSpace (resolving the triple raises on a
      # dead credential before the snapshot is taken): a pin to a credential already
      # known to be unusable would turn today's clear "no credential" failure into the
      # far more confusing "pinned credential missing".
      it 'leaves the pin NULL when no enabled credential resolves' do
        provider_default.update!(enabled: false)

        expect(described_class.embedding_credentials_for(organisation))
          .to include(ai_credential_id: nil)
      end
    end
  end

  # require_tenant = true: resolving the pointer through the acts_as_tenant-scoped
  # association would answer nil under a foreign tenant and silently fall back to the
  # configuration — B1 broken again, by another route. The explicit organisation_id
  # predicate is what prevents that.
  describe 'pointer resolution is independent of the ambient tenant' do
    let!(:old_space) do
      create(:embedding_space, organisation: organisation, embedding_model: 'ada', embedding_dims: 1536)
    end
    let(:other_org) { create(:organisation, name: 'Other', subdomain: 'other-tenant') }

    before do
      create(:ai_credential, :active, :embedding_only, provider: 'openai', access_token: 'sk-system')
      organisation.update!(active_embedding_space_id: old_space.id, embedding_dims: 1024)
    end

    it 'resolves the active space under a FOREIGN ambient tenant' do
      resolved = ActsAsTenant.with_tenant(other_org) do
        described_class.embedding_space_for(organisation, space: :active)
      end

      expect(resolved).to include(embedding_model: 'ada', embedding_dims: 1536)
    end

    it 'resolves the active space with NO ambient tenant at all' do
      resolved = ActsAsTenant.without_tenant do
        described_class.embedding_space_for(organisation, space: :active)
      end

      expect(resolved).to include(embedding_model: 'ada', embedding_dims: 1536)
    end

    # Cross-org safety of the explicit read: a pointer that names another org's row
    # must not resolve (UUID collision is impossible in practice, but the predicate is
    # what makes that a guarantee rather than an accident).
    it 'ignores a pointer naming another organisation space' do
      foreign = ActsAsTenant.with_tenant(other_org) { create(:embedding_space, organisation: other_org) }
      organisation.update_column(:active_embedding_space_id, foreign.id)

      expect(described_class.embedding_space_for(organisation, space: :active))
        .to eq(described_class.embedding_space_for(organisation, space: :configured))
    end
  end
end
