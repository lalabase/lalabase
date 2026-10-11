# frozen_string_literal: true

require 'rails_helper'

# Covers the ada-002 → text-embedding-3-small rollout task. Intent per example:
# WHICH orgs the migrator touches (only system-default ones), that it relabels a
# materialised legacy default to nil, that BYOK/divergent orgs are left alone, and
# that a second run is a no-op. The actual re-embedding is stubbed here — its own
# behaviour lives in organisation_reindexer_spec.
RSpec.describe Embeddings::DefaultModelMigrator do
  # Stub the reindexer so no example reaches the real Factory/OpenAI. It returns an
  # empty per-model hash; we assert on WHO gets reindexed, not on vector output.
  #
  # Stubbed on the CLASS-LEVEL .call — the entry point since the PR-6a service-convention
  # migration. Stubbing .new instead would keep passing if this caller fell back to
  # `.new(...).call`, so the convention could rot away here unnoticed (review A-5).
  let(:reindexer) { Embeddings::OrganisationReindexer }

  before { allow(Embeddings::OrganisationReindexer).to receive(:call).and_return({}) }

  def run(reindex: true)
    described_class.new(reindex: reindex, logger: Logger.new(nil)).call
  end

  describe '#call — selection' do
    it 'processes a nil/nil system-default org and re-embeds it' do
      org = create(:organisation, subdomain: 'sysdefault',
                                  embedding_provider: nil, embedding_model: nil)

      summary = run

      expect(summary.results.map(&:organisation_id)).to contain_exactly(org.id)
      expect(summary.skipped).to eq(0)
      expect(reindexer).to have_received(:call).once
    end

    it 'leaves a BYOK org (own embedding_access_token) untouched' do
      byok = create(:organisation, subdomain: 'byok', embedding_provider: 'openai',
                                   embedding_access_token: 'sk-byok-secret')

      summary = run

      expect(summary.results).to be_empty
      expect(summary.skipped).to eq(1)
      expect(reindexer).not_to have_received(:call)
      expect(byok.reload.embedding_access_token).to eq('sk-byok-secret')
    end

    it 'leaves an org on a different provider (openai_compatible) untouched' do
      create(:organisation, subdomain: 'compat', embedding_provider: 'openai_compatible')

      summary = run

      expect(summary.results).to be_empty
      expect(summary.skipped).to eq(1)
      expect(reindexer).not_to have_received(:call)
    end

    it 'leaves an org pinned to a non-legacy model untouched' do
      create(:organisation, subdomain: 'pinned',
                            embedding_provider: 'openai', embedding_model: 'text-embedding-3-large')

      summary = run

      expect(summary.results).to be_empty
      expect(summary.skipped).to eq(1)
      expect(reindexer).not_to have_received(:call)
    end

    it 'processes system-default orgs and skips BYOK/divergent in one mixed run' do
      sys_default = create(:organisation, subdomain: 'mixed-sys', embedding_provider: 'openai')
      create(:organisation, subdomain: 'mixed-byok', embedding_provider: 'openai',
                            embedding_access_token: 'sk-x')
      create(:organisation, subdomain: 'mixed-compat', embedding_provider: 'openai_compatible')

      summary = run

      expect(summary.migrated).to eq(1)
      expect(summary.skipped).to eq(2)
      expect(summary.results.map(&:organisation_id)).to contain_exactly(sys_default.id)
    end
  end

  describe '#call — model normalisation' do
    it 'resets a materialised legacy ada-002 model to nil (follow system default)' do
      org = create(:organisation, subdomain: 'legacy', embedding_provider: 'openai',
                                  embedding_model: 'text-embedding-ada-002')

      result = run(reindex: false).results.first

      expect(result.normalised).to be(true)
      expect(org.reload.embedding_model).to be_nil
    end

    it 'does not write when the model is already nil' do
      create(:organisation, subdomain: 'already-nil', embedding_provider: 'openai', embedding_model: nil)

      expect(run(reindex: false).results.first.normalised).to be(false)
    end

    it 'is idempotent — a second run normalises nothing' do
      create(:organisation, subdomain: 'idem', embedding_provider: 'openai',
                            embedding_model: 'text-embedding-ada-002')

      run(reindex: false)
      second = run(reindex: false)

      expect(second.results.first.normalised).to be(false)
    end
  end

  describe '#call — reindex resilience' do
    it 'skips (logs) an org whose reindex raises a provider error instead of aborting the run' do
      create(:organisation, subdomain: 'no-cred', embedding_provider: 'openai')
      allow(reindexer).to receive(:call)
        .and_raise(Lalabase::Llm::Factory::MissingCredentialError, 'no credential')

      summary = run

      expect(summary.migrated).to eq(1)
      expect(summary.results.first.reindex).to be_nil
    end
  end
end
