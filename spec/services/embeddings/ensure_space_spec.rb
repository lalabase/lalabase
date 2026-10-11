# frozen_string_literal: true

require 'rails_helper'

# What this file protects
# -----------------------
# Embeddings::EnsureSpace had no spec (review finding T4, 2026-08-01), including its two
# load-bearing properties:
#
#   1. Token rotation to the SAME triple REFRESHES the row instead of creating a second
#      space. Without that, every credential change would fork a new vector space and
#      the corpus would scatter across spaces nobody built.
#   2. The triple comes from the RESOLVED configuration, not the raw org columns — only
#      the resolved form carries the normalisation the write paths stamp (provider
#      routing key, effective model, clamped dimension). A row keyed on raw columns
#      would name a space no sidecar row ever lands in.
RSpec.describe Embeddings::EnsureSpace do
  let(:organisation) { create(:organisation) }

  let!(:system_credential) do
    create(:ai_credential, :active, :embedding_only, provider: 'openai', access_token: 'sk-system')
  end

  before { ActsAsTenant.current_tenant = organisation }

  after { ActsAsTenant.current_tenant = nil }

  it 'creates the row for the org configured triple' do
    space = described_class.call(organisation: organisation)

    expect(space.triple).to eq(
      Lalabase::Llm::Factory.embedding_space_for(organisation, space: :configured)
    )
  end

  it 'is idempotent — a second call returns the same row' do
    first = described_class.call(organisation: organisation)

    expect { described_class.call(organisation: organisation) }
      .not_to(change { EmbeddingSpace.where(organisation_id: organisation.id).count })
    expect(described_class.call(organisation: organisation).id).to eq(first.id)
  end

  describe 'credential snapshot' do
    it 'stores the org BYOK credentials' do
      organisation.update!(embedding_provider: 'openai_compatible', embedding_model: 'bge-1536',
                           embedding_api_base: 'https://one.example.test/v1',
                           embedding_access_token: 'sk-one')

      space = described_class.call(organisation: organisation)

      expect(space).to have_attributes(api_base: 'https://one.example.test/v1', access_token: 'sk-one')
    end

    # A BYOK row carries its own secret, so there is no system credential to address —
    # pinning one here would attribute the org's own spend to our credential.
    it 'leaves the credential pin NULL on the BYOK path' do
      organisation.update!(embedding_provider: 'openai_compatible', embedding_model: 'bge-1536',
                           embedding_api_base: 'https://one.example.test/v1',
                           embedding_access_token: 'sk-one')

      space = described_class.call(organisation: organisation)

      expect(space.ai_credential_id).to be_nil
    end

    # Rotation, not a new space: the triple is unchanged, so the vectors stay valid.
    # A second row here would silently split the corpus.
    it 'REFRESHES the row on token rotation to the same triple' do
      organisation.update!(embedding_provider: 'openai_compatible', embedding_model: 'bge-1536',
                           embedding_api_base: 'https://one.example.test/v1',
                           embedding_access_token: 'sk-old')
      first = described_class.call(organisation: organisation)

      organisation.update!(embedding_access_token: 'sk-rotated')
      second = described_class.call(organisation: organisation)

      expect(second.id).to eq(first.id)
      expect(second.access_token).to eq('sk-rotated')
      expect(EmbeddingSpace.where(organisation_id: organisation.id).count).to eq(1)
    end

    # A DIFFERENT triple is a different space — that is the whole point of the key.
    it 'creates a SECOND row when the triple itself changes' do
      described_class.call(organisation: organisation)

      organisation.update!(embedding_provider: 'openai_compatible', embedding_model: 'bge-1536',
                           embedding_api_base: 'https://two.example.test/v1',
                           embedding_access_token: 'sk-two')
      described_class.call(organisation: organisation)

      expect(EmbeddingSpace.where(organisation_id: organisation.id).count).to eq(2)
    end

    # NULL means "resolve the system credential", so dropping BYOK must clear the
    # snapshot — leaving the old token would keep a revoked secret alive in the row.
    it 'clears the snapshot when the org drops its BYOK setup for the same triple' do
      # A system credential for the same provider must exist — without a token of its
      # own the org falls back to it, and its default_model is what keeps the triple
      # unchanged across the two calls.
      compatible = create(:ai_credential, :active, :embedding_only, provider: 'openai_compatible',
                                                                    access_token: 'sk-sys-compatible',
                                                                    default_model: 'bge-1536',
                                                                    additional_config: { 'uri_base' => 'https://sys.example.test/v1' })
      organisation.update!(embedding_provider: 'openai_compatible', embedding_model: 'bge-1536',
                           embedding_api_base: 'https://one.example.test/v1',
                           embedding_access_token: 'sk-one')
      first = described_class.call(organisation: organisation)

      organisation.update!(embedding_access_token: nil)
      space = described_class.call(organisation: organisation)

      expect(space.id).to eq(first.id)
      expect(space.access_token).to be_nil
      # Dropping BYOK does not just clear the secret, it hands the row over to a
      # NAMED system credential — the pin is what records which one (P0).
      expect(space.ai_credential_id).to eq(compatible.id)
    end

    it 'stores no copy of the system credential on the system path' do
      space = described_class.call(organisation: organisation)

      expect([space.access_token, space.api_base, space.organization_id]).to all(be_nil)
    end

    # The pin is the exception to "no copy": an id is not a secret and does not freeze
    # the rotating token — it freezes WHICH credential this space belongs to, so a
    # second system credential of the same provider cannot take the row over (P0).
    it 'pins the resolved system credential by id on the system path' do
      space = described_class.call(organisation: organisation)

      expect(space.ai_credential_id).to eq(system_credential.id)
    end

    # THE point of the column, on the refresh path. Every other snapshot value here is
    # rewritten on each call; re-resolving the pin too would hand the held space to
    # whichever credential owns the provider's default slot today — the swap the column
    # exists to prevent, reached through `flip`/`build_target` instead of through a read.
    it 'keeps an existing pin when another credential has become the provider default' do
      first = described_class.call(organisation: organisation)
      successor = create(:ai_credential, :embedding_only, provider: 'openai',
                                                          access_token: 'sk-successor',
                                                          default_model: system_credential.default_model)
      AiCredential.activate!(successor.id)

      space = described_class.call(organisation: organisation)

      expect(space.id).to eq(first.id)
      expect(space.ai_credential_id).to eq(system_credential.id)
      expect(AiCredential.active_for_provider('openai')).to eq(successor)
    end

    # A divergence is legitimate, not a fault — but silent it would look like the pin
    # had followed the default. Once per refresh is what makes the P1 repoint an
    # explicit act instead of something a reindex quietly did.
    it 'warns when the pin and the current provider default diverge' do
      described_class.call(organisation: organisation)
      successor = create(:ai_credential, :embedding_only, provider: 'openai',
                                                          access_token: 'sk-successor',
                                                          default_model: system_credential.default_model)
      AiCredential.activate!(successor.id)

      expect(Rails.logger).to receive(:warn).with(/stays pinned to credential/)

      described_class.call(organisation: organisation)
    end

    # The one case that still clears the pin: from here on the row's own token serves it,
    # and the read path (Factory#descriptor_from_space) never consults a pin again — a
    # leftover would name a credential nothing reads.
    it 'clears the pin when a pinned row switches to BYOK' do
      first = described_class.call(organisation: organisation)
      expect(first.ai_credential_id).to eq(system_credential.id)

      organisation.update!(embedding_access_token: 'sk-own',
                           embedding_api_base: 'https://own.example.test/v1')
      space = described_class.call(organisation: organisation)

      expect(space.id).to eq(first.id)
      expect(space.ai_credential_id).to be_nil
    end
  end

  it 'scopes the row to the organisation it was called for' do
    other = create(:organisation, name: 'Other', subdomain: 'other-ensure')

    space = ActsAsTenant.with_tenant(other) { described_class.call(organisation: other) }

    expect(space.organisation_id).to eq(other.id)
  end
end
