# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Embeddings::OrganisationReindexer do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:target_vector) { Array.new(1536, 0.5) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  # Tokens the fake endpoint reports per embedded text. A distinctive number, not
  # 1: it makes the usage assertions read as "7 per text × n texts" rather than as
  # a record count that would also match a wrong sum.
  let(:tokens_per_text) { 7 }

  # A fake target provider standing in for an OpenAI-compatible endpoint the org
  # switched to. embed_batch_with_usage echoes one target vector per input text
  # and reports the tokens the run is billed for.
  #
  # billing_credential is stubbed to nil ON PURPOSE rather than left unstubbed:
  # UsageTracking.record_embedding rescues StandardError, so an instance_double
  # raising on an unstubbed call would turn every booking in this file into a
  # silently logged no-op — and the metering examples below would pass without
  # ever writing a row. nil is the BYOK reading (logged, costs us nothing).
  def fake_provider(name: 'openai_compatible', model: 'bge-1536')
    instance_double(Lalabase::Llm::OpenAiCompatibleProvider,
                    provider_name: name,
                    default_embedding_model: model,
                    billing_credential: nil,
                    expected_embedding_dims: 1536).tap do |p|
      # model: is part of the signature since PR 6a — the reindexer passes the target
      # space's model explicitly, because OpenAiProvider/GoogleVertexProvider answer
      # #default_embedding_model from a constant and would otherwise embed a roll-back
      # with today's model.
      allow(p).to receive(:embed_batch_with_usage) do |texts:, **_kwargs|
        { embeddings: texts.map { target_vector }, total_tokens: tokens_per_text * texts.size }
      end
    end
  end

  def run(provider)
    described_class.new(organisation: organisation, metered: true, provider: provider).call
  end

  describe '#call' do
    it 're-embeds stale fragments and stamps the new provenance' do
      fragment = create(:fragment, :for_ticket, organisation: organisation)

      result = run(fake_provider)['Fragment']

      expect(result.reindexed).to eq(1)
      expect(result.skipped).to eq(0)
      # The provenance lives on the sidecar row since PR 7 — as the full TRIPLE, which
      # is what the read seam filters on (the old inline pair could not carry dims).
      row = ContentEmbedding.find_by(embeddable: fragment)
      expect(row).to have_attributes(embedding_provider: 'openai_compatible',
                                     embedding_model: 'bge-1536', embedding_dims: 1536)
      expect(row.embedding).to be_present
    end

    it 'skips rows that already have a sidecar row in the target space (no re-embed call)' do
      fragment = create(:fragment, :for_ticket, organisation: organisation)
      # The state a fully backfilled/reindexed org is in: a sidecar row in the
      # TARGET triple. That row — not the inline pair — is what makes it a skip
      # since PR 5 (sheet §3.3).
      create(:content_embedding, organisation: organisation, embeddable: fragment,
                                 embedding_provider: 'openai_compatible', embedding_model: 'bge-1536',
                                 embedding_dims: 1536)
      provider = fake_provider

      result = run(provider)['Fragment']

      expect(result.reindexed).to eq(0)
      expect(result.skipped).to eq(1)
      expect(provider).not_to have_received(:embed_batch_with_usage)
    end

    # force: bypasses the stale skip and re-embeds EVERY target row — the same
    # already-on-target row the test above skips (reindexed=0) is re-embedded here
    # (reindexed=1). This is what heals pre-backfill source_hash drift (#354 #1).
    it 'force: re-embeds even a row already on the target provider/model' do
      create(:fragment, :for_ticket, organisation: organisation)
      provider = fake_provider

      result = described_class.new(organisation: organisation, metered: true, provider: provider, force: true).call['Fragment']

      expect(result.reindexed).to eq(1)
      expect(result.skipped).to eq(0)
      expect(provider).to have_received(:embed_batch_with_usage)
    end

    it 're-embeds across all four embedded tables' do
      repo = create(:project_repository, organisation: organisation, project: project)
      create(:code_symbol, organisation: organisation, project_repository: repo)
      create(:project_capability, organisation: organisation, project: project)
      create(:project_layer4_vision, organisation: organisation, project: project)
      create(:fragment, :for_ticket, organisation: organisation)

      results = run(fake_provider)

      expect(results['CodeSymbol'].reindexed).to eq(1)
      expect(results['ProjectCapability'].reindexed).to eq(1)
      expect(results['ProjectLayer4Vision'].reindexed).to eq(1)
      expect(results['Fragment'].reindexed).to eq(1)
    end

    it 'does not touch another organisation rows (tenant isolation)' do
      other_org = create(:organisation, name: 'Other', subdomain: 'other')
      other_project = create(:project, organisation: other_org)
      other_fragment = ActsAsTenant.with_tenant(other_org) do
        create(:fragment, fragmentable: create(:ticket, project: other_project, organisation: other_org),
                          organisation: other_org)
      end

      run(fake_provider)

      # Stronger than the old inline-pair assertion: the foreign record gets no row in
      # the target space at all, so nothing about it was touched or embedded.
      expect(ContentEmbedding.where(embeddable: other_fragment)).to be_empty
    end

    it 'raises when the provider returns the wrong number of vectors' do
      create(:fragment, :for_ticket, organisation: organisation)
      provider = instance_double(Lalabase::Llm::OpenAiCompatibleProvider,
                                 provider_name: 'openai_compatible', default_embedding_model: 'bge-1536',
                                 expected_embedding_dims: 1536)
      allow(provider).to receive(:embed_batch_with_usage)
        .and_return({ embeddings: [], total_tokens: 0 }) # 0 vectors for 1 row

      expect { run(provider) }.to raise_error(/embed_batch returned 0 vectors/)
    end

    it 'is idempotent — a second run re-embeds nothing' do
      create(:fragment, :for_ticket, organisation: organisation)
      provider = fake_provider

      run(provider)
      second = described_class.new(organisation: organisation, metered: true, provider: fake_provider).call['Fragment']

      expect(second.reindexed).to eq(0)
    end
  end

  # KI-Pakete P4a+ (doc/ki_pakete_p4_plan.md E6). Until P4a only an operator could
  # start a reindex, and it wrote no AiUsage row at all — a blind cost path (plan
  # §2.4 finding 1). P4a hands the trigger to the customer AND charges the credits
  # against their monthly quota, so the booking is part of that slice, not a later
  # nicety: without it every customer switch grows a bill nothing can attribute.
  describe 'metering' do
    it 'books ONE row for the whole run, summing tokens across all four tables' do
      repo = create(:project_repository, organisation: organisation, project: project)
      create(:code_symbol, organisation: organisation, project_repository: repo)
      create(:project_capability, organisation: organisation, project: project)
      create(:project_layer4_vision, organisation: organisation, project: project)
      create(:fragment, :for_ticket, organisation: organisation)

      expect { run(fake_provider) }.to change(AiUsage, :count).by(1)

      usage = AiUsage.last
      # Four records, one per table — the assertion is on the SUM, which is what
      # separates "booked once for the run" from "booked once per table" (the
      # latter would also be 1 row here if only the last table were booked).
      expect(usage.tokens_used).to eq(4 * tokens_per_text)
      expect(usage.action).to eq(Lalabase::Llm::ActionRegistry::DOCUMENT_INDEXING)
      expect(usage.metadata['fragment_count']).to eq(4)
    end

    it 'stamps the TARGET space model, not the provider default' do
      space = create(:embedding_space, organisation: organisation,
                                       embedding_provider: 'openai', embedding_model: 'text-embedding-ada-002',
                                       embedding_dims: 1536)
      create(:fragment, :for_ticket, organisation: organisation)
      # Same constant trap the roll-back examples pin: the provider answers a
      # DIFFERENT model than the space being rebuilt. A bill naming the provider's
      # model would attribute the spend to a space this run never wrote to.
      provider = fake_provider(name: 'openai', model: 'text-embedding-3-small')

      described_class.new(organisation: organisation, metered: true, provider: provider, target_space: space).call

      expect(AiUsage.last.model_used).to eq('text-embedding-ada-002')
    end

    it 'books nothing when the run embedded nothing' do
      create(:fragment, :for_ticket, organisation: organisation)
      run(fake_provider)

      # The idempotent re-run — the COMMON case, since the P4d watcher re-drives an
      # unfinished switch. A zero-token row per attempt would turn a healing loop
      # into a stream of empty usage rows.
      expect { described_class.new(organisation: organisation, metered: true, provider: fake_provider).call }
        .not_to change(AiUsage, :count)
    end

    it 'books nothing when the provider reported no tokens' do
      create(:fragment, :for_ticket, organisation: organisation)
      provider = fake_provider
      # An endpoint that omits the usage block (a self-hosted openai_compatible
      # deployment may). The vectors land — the run is NOT a failure — but there is
      # nothing to bill, and inventing a zero-credit row would claim the run was
      # measured when it was not.
      allow(provider).to receive(:embed_batch_with_usage) do |texts:, **_kwargs|
        { embeddings: texts.map { target_vector }, total_tokens: 0 }
      end

      expect { run(provider) }.not_to change(AiUsage, :count)
      expect(ContentEmbedding.count).to eq(1)
    end

    # THE half of E6 that "erfassen UND anrechnen" is actually about, and the half
    # every example above misses: they all stub billing_credential to nil, i.e. the
    # BYOK path — the one that is logged and explicitly NOT charged. A regression
    # that booked 0 credits, or wrote a row that AiUsage.quota_counted cannot see,
    # would stay green in all of them.
    it 'charges credits against the quota when the space runs on a metered credential' do
      credential = create(:ai_credential, :embedding_only, included_in_quota: true)
      provider = fake_provider
      allow(provider).to receive(:billing_credential).and_return(credential)
      create(:fragment, :for_ticket, organisation: organisation)

      described_class.new(organisation: organisation, metered: true, provider: provider).call

      usage = AiUsage.last
      # document_indexing is token-metered at 1 credit per STARTED 1k tokens
      # (ActionRegistry), so 7 tokens is 1 — not 0, which is what a run that lost
      # its token sum on the way to credits_for would book.
      expect(usage.tokens_used).to eq(tokens_per_text)
      expect(usage.credits_used).to eq(1)
      # Presence is not enough: quota_counted INNER JOINs the credential, so a row
      # written without one is invisible to the budget while looking perfectly fine
      # in the usage list.
      expect(AiUsage.quota_counted).to include(usage)
    end

    # K2 (review of #422). The booking sits in this class, and this class has five
    # callers — only ONE of them is the customer. rake and DefaultModelMigrator
    # (the ada-002 rollout) run because WE changed something; billing a customer's
    # monthly budget for our own migration would also push them towards the quota
    # gate and break their chat and search as a side effect of an operator repair.
    it 'books nothing at all for an operator run' do
      credential = create(:ai_credential, :embedding_only, included_in_quota: true)
      provider = fake_provider
      allow(provider).to receive(:billing_credential).and_return(credential)
      create(:fragment, :for_ticket, organisation: organisation)

      expect { described_class.new(organisation: organisation, metered: false, provider: provider).call }
        .not_to change(AiUsage, :count)
      # The work still happened — unmetered means unattributed, not skipped.
      expect(ContentEmbedding.count).to eq(1)
    end

    # I4 (review of #422). A run that dies on table 4 has already PAID for tables
    # 1-3. Booking only on the happy path would drop that spend silently — and
    # P4d's watcher re-drives an unfinished switch, so the same tokens would be
    # lost again on every attempt: the blind cost path this slice closes, returning
    # through the error case.
    it 'still books the tokens a run spent before it died' do
      create(:fragment, :for_ticket, organisation: organisation)
      provider = fake_provider
      call_count = 0
      allow(provider).to receive(:embed_batch_with_usage) do |texts:, **_kwargs|
        call_count += 1
        raise 'endpoint exploded' if call_count > 1

        { embeddings: texts.map { target_vector }, total_tokens: tokens_per_text * texts.size }
      end
      # A second table with work in it, so the first batch succeeds (and is paid
      # for) before the second one blows up.
      create(:project_capability, organisation: organisation, project: project)

      expect { described_class.new(organisation: organisation, metered: true, provider: provider).call }
        .to raise_error('endpoint exploded')

      expect(AiUsage.last.tokens_used).to eq(tokens_per_text)
    end
  end

  # Write-both (embedding v2 PR 2): the reindexer keeps writing inline (reads!) AND
  # upserts a sidecar row in the TARGET vector space.
  describe 'sidecar write-both' do
    it 'upserts a sidecar row with the target triple + source_hash for each re-embedded record' do
      fragment = create(:fragment, :for_ticket, organisation: organisation,
                                                plain_text_content: 'reindex me')
      run(fake_provider)

      row = ContentEmbedding.find_by(embeddable: fragment)
      expect(row).to have_attributes(
        organisation_id: organisation.id,
        embedding_provider: 'openai_compatible', embedding_model: 'bge-1536', embedding_dims: 1536,
        source_hash: ContentEmbedding.source_hash_for('reindex me'), indexed: true
      )
      expect(row.embedding.to_a).to eq(target_vector)
    end

    # Since PR 5 an existing TARGET-space row makes the record a skip (§3.3), so the
    # upsert is reached through force: — which is exactly the documented path for
    # healing pre-backfill source_hash drift. It must UPDATE that row, not collide
    # on idx_content_embeddings_unique_space.
    it 'force: UPDATES an existing target-space sidecar row instead of duplicating (upsert)' do
      fragment = create(:fragment, :for_ticket, organisation: organisation,
                                                plain_text_content: 'reindex me')
      # A sidecar row already in the TARGET space (as write-both would leave), but
      # with a source_hash from an older text version.
      create(:content_embedding, organisation: organisation, embeddable: fragment,
                                 embedding_provider: 'openai_compatible', embedding_model: 'bge-1536',
                                 embedding_dims: 1536, source_hash: ContentEmbedding.source_hash_for('old'))

      expect { described_class.new(organisation: organisation, metered: true, provider: fake_provider, force: true).call }
        .not_to change(ContentEmbedding, :count)
      expect(ContentEmbedding.find_by(embeddable: fragment).source_hash)
        .to eq(ContentEmbedding.source_hash_for('reindex me'))
    end

    it 'skips a record that already has a target-space row (the drift stays until force:)' do
      fragment = create(:fragment, :for_ticket, organisation: organisation,
                                                plain_text_content: 'reindex me')
      create(:content_embedding, organisation: organisation, embeddable: fragment,
                                 embedding_provider: 'openai_compatible', embedding_model: 'bge-1536',
                                 embedding_dims: 1536, source_hash: ContentEmbedding.source_hash_for('old'))

      expect(run(fake_provider)['Fragment'].reindexed).to eq(0)
      expect(ContentEmbedding.find_by(embeddable: fragment).source_hash)
        .to eq(ContentEmbedding.source_hash_for('old'))
    end

    # A failing batch leaves NOTHING behind. Until PR 7 this pinned the m1 transaction
    # bracket around two writes (the inline update_columns and the sidecar upsert);
    # only the sidecar upsert is left, so the guarantee now rests on that statement
    # being atomic by itself. The example stays because the OUTCOME is the contract:
    # a failed re-embed must not leave a partial row, and the failure must be loud
    # rather than counted as success.
    it 'leaves no row behind and propagates the error when the sidecar upsert fails' do
      fragment = create(:fragment, :for_ticket, organisation: organisation,
                                                plain_text_content: 'reindex me')
      allow(ContentEmbedding).to receive(:upsert_all).and_raise(ActiveRecord::StatementInvalid, 'boom')

      expect { run(fake_provider) }.to raise_error(ActiveRecord::StatementInvalid, /boom/)

      expect(ContentEmbedding.where(embeddable: fragment)).to be_empty
    end

    it 'writes no sidecar rows for another organisation (tenant scoping)' do
      other_org = create(:organisation, name: 'OtherSC', subdomain: 'othersc')
      other_project = create(:project, organisation: other_org)
      other_fragment = ActsAsTenant.with_tenant(other_org) do
        create(:fragment, fragmentable: create(:ticket, project: other_project, organisation: other_org),
                          organisation: other_org)
      end

      run(fake_provider)

      expect(ContentEmbedding.unscoped.where(embeddable: other_fragment)).to be_empty
    end
  end

  # Dims-only switch (embedding v2 PR 5, sheet §2.4/§3.3). Provider and model stay
  # the same, only the dimension changes (e.g. Matryoshka truncation of the 3-family).
  # The old candidate filter compared the inline PAIR only — the inline tables have no
  # dims column, so such a switch was invisible: "reindexed 0" while the gate stayed
  # red. The anti-join asks the sidecar the same question the read seam asks.
  describe 'dims-only switch' do
    let(:vector1024) { Array.new(1024, 0.5) }

    def provider1024(name: 'openai', model: 'text-embedding-3-small')
      instance_double(Lalabase::Llm::OpenAiProvider,
                      provider_name: name, default_embedding_model: model,
                      billing_credential: nil,
                      expected_embedding_dims: 1024).tap do |p|
        allow(p).to receive(:embed_batch_with_usage) do |texts:, **_kwargs|
          { embeddings: texts.map { vector1024 }, total_tokens: tokens_per_text * texts.size }
        end
      end
    end

    # The §2.4 repro: identical provider/model, only the dim moved.
    it 'finds the record as a candidate although provider and model are unchanged' do
      fragment = create(:fragment, :for_ticket, organisation: organisation)
      create(:content_embedding, organisation: organisation, embeddable: fragment,
                                 embedding_provider: 'openai',
                                 embedding_model: 'text-embedding-3-small', embedding_dims: 1536)

      result = run(provider1024)['Fragment']

      expect(result.reindexed).to eq(1)
      expect(ContentEmbedding.where(embeddable: fragment, embedding_dims: 1024).count).to eq(1)
    end

    # What PR 7 removed, pinned from the other side. Until then a dims-only switch left
    # the stale 1536 vector in the inline column while stamping the NEW provenance pair
    # next to it — a row claiming a space its vector did not belong to (the one
    # dishonesty of the PR-5 cut). There is no inline column now, so the only thing a
    # dims switch produces is a SECOND sidecar row, and the old one keeps its own
    # honest triple. Reintroducing an in-place vector update would have to lie again.
    it 'adds a row in the target space and leaves the old row stamped with ITS space' do
      fragment = create(:fragment, :for_ticket, organisation: organisation)
      old_row = create(:content_embedding, organisation: organisation, embeddable: fragment,
                                           embedding_provider: 'openai',
                                           embedding_model: 'text-embedding-3-small',
                                           embedding_dims: 1536)

      run(provider1024)

      expect(ContentEmbedding.where(embeddable: fragment).count).to eq(2)
      expect(old_row.reload).to have_attributes(embedding_model: 'text-embedding-3-small',
                                                embedding_dims: 1536)
      expect(ContentEmbedding.find_by(embeddable: fragment, embedding_dims: 1024)).to be_present
    end

    it 'writes the 1024 vector to the sidecar with the full target triple' do
      fragment = create(:fragment, :for_ticket, organisation: organisation,
                                                plain_text_content: 'reindex me')

      run(provider1024)

      row = ContentEmbedding.find_by(embeddable: fragment)
      expect(row).to have_attributes(embedding_provider: 'openai',
                                     embedding_model: 'text-embedding-3-small',
                                     embedding_dims: 1024, indexed: true,
                                     source_hash: ContentEmbedding.source_hash_for('reindex me'))
      expect(row.embedding.to_a).to eq(vector1024)
    end

    # The switch BACK is cheap: the old rows are still there (only `stale`), so only
    # records created since the switch need re-embedding (sheet §3.3).
    it 'only re-embeds records without a row in the target space when switching back' do
      old_fragment = create(:fragment, :for_ticket, organisation: organisation)
      create(:content_embedding, organisation: organisation, embeddable: old_fragment,
                                 embedding_provider: 'openai_compatible',
                                 embedding_model: 'bge-1536', embedding_dims: 1536)
      create(:fragment, :for_ticket, organisation: organisation)

      expect(run(fake_provider)['Fragment'].reindexed).to eq(1)
    end

    # Review finding S2: "already done" must mean READABLE, the way the read seam and
    # Embeddings::SpaceAlignment define it (full triple AND indexed) — not merely
    # "a row exists". Without the `indexed` predicate in the anti-join a retired row
    # would count as a finished re-index while no query can see it: the task reports
    # "reindexed 0" and the gate stays red, the exact failure §3.3 exists to kill.
    # No writer sets indexed: false today; PR 6 (retention, pointer flips) does.
    it 're-embeds a record whose only row in the target space is not indexed' do
      fragment = create(:fragment, :for_ticket, organisation: organisation)
      # fake_provider's own triple — anything else would make this pass for the
      # trivial reason that the space does not match at all.
      create(:content_embedding, organisation: organisation, embeddable: fragment,
                                 embedding_provider: 'openai_compatible', embedding_model: 'bge-1536',
                                 embedding_dims: 1536, indexed: false)

      expect(run(fake_provider)['Fragment'].reindexed).to eq(1)
    end

    # Counterpart, so the predicate cannot flip into "ignore the flag entirely":
    # the SAME row with indexed: true is a skip. Together the pair pins the flag as
    # the only difference.
    it 'skips a record whose row in the target space IS indexed' do
      fragment = create(:fragment, :for_ticket, organisation: organisation)
      create(:content_embedding, organisation: organisation, embeddable: fragment,
                                 embedding_provider: 'openai_compatible', embedding_model: 'bge-1536',
                                 embedding_dims: 1536, indexed: true)

      expect(run(fake_provider)['Fragment'].reindexed).to eq(0)
    end
  end

  # Delta mode (embedding v2 PR 6a): the roll-back / healing run. It is a SUPERSET of
  # the default build mode — drift AND records with no readable target row — because a
  # mode that found only drift would skip exactly the records created since the switch,
  # which is the bulk of what a roll-back has to catch up on.
  describe 'delta mode' do
    def delta_run(provider)
      described_class.new(organisation: organisation, metered: true, provider: provider, delta: true).call
    end

    # The pairing that gives this block teeth: same setup, one record edited. Only the
    # edited one may be re-embedded, and the counter must name it as DRIFT rather than
    # as build work.
    it 're-embeds a record whose source text drifted, and skips the unchanged one' do
      drifted = create(:fragment, :for_ticket, organisation: organisation,
                                               plain_text_content: 'original text')
      unchanged = create(:fragment, :for_ticket, organisation: organisation,
                                                 plain_text_content: 'stable text')
      [drifted, unchanged].each do |fragment|
        create(:content_embedding, organisation: organisation, embeddable: fragment,
                                   embedding_provider: 'openai_compatible', embedding_model: 'bge-1536',
                                   embedding_dims: 1536, indexed: true,
                                   source_hash: ContentEmbedding.source_hash_for(fragment.plain_text_content))
      end
      drifted.update_columns(plain_text_content: 'edited text')

      result = delta_run(fake_provider)['Fragment']

      expect(result.reindexed).to eq(1)
      expect(result.stale_reembedded).to eq(1)
      expect(ContentEmbedding.find_by(embeddable_id: drifted.id).source_hash)
        .to eq(ContentEmbedding.source_hash_for('edited text'))
    end

    it 'also picks up records with NO readable row in the target space (superset of build)' do
      create(:fragment, :for_ticket, organisation: organisation, plain_text_content: 'brand new')

      result = delta_run(fake_provider)['Fragment']

      # Counted as build work, NOT as drift — the two numbers answer different questions.
      expect(result.reindexed).to eq(1)
      expect(result.stale_reembedded).to eq(0)
    end

    it 'skips everything when nothing drifted (a no-op costs no tokens)' do
      fragment = create(:fragment, :for_ticket, organisation: organisation, plain_text_content: 'stable')
      create(:content_embedding, organisation: organisation, embeddable: fragment,
                                 embedding_provider: 'openai_compatible', embedding_model: 'bge-1536',
                                 embedding_dims: 1536, indexed: true,
                                 source_hash: ContentEmbedding.source_hash_for('stable'))
      provider = fake_provider

      result = delta_run(provider)['Fragment']

      expect(result.reindexed).to eq(0)
      expect(result.stale_reembedded).to eq(0)
      expect(provider).not_to have_received(:embed_batch_with_usage)
    end

    # Outside delta mode the concept does not apply — nil, not 0, so a reader cannot
    # mistake "not measured" for "measured zero".
    it 'reports stale_reembedded as nil in build mode' do
      create(:fragment, :for_ticket, organisation: organisation)

      expect(run(fake_provider)['Fragment'].stale_reembedded).to be_nil
    end

    it 'refuses to combine force and delta (force is the superset)' do
      expect { described_class.new(organisation: organisation, metered: true, force: true, delta: true) }
        .to raise_error(ArgumentError, /mutually exclusive/)
    end
  end

  # target_space: pins the space being written to — the roll-back path. Without it the
  # triple would be derived from the provider, and OpenAiProvider/GoogleVertexProvider
  # answer #default_embedding_model from a CONSTANT: a roll-back would then stamp rows
  # into TODAY's space while claiming to rebuild an older one (sheet §0.1).
  describe 'target_space: (roll-back)' do
    it 'stamps rows with the SPACE triple, not the provider default' do
      space = create(:embedding_space, organisation: organisation,
                                       embedding_provider: 'openai', embedding_model: 'text-embedding-ada-002',
                                       embedding_dims: 1536)
      fragment = create(:fragment, :for_ticket, organisation: organisation)
      # A provider whose OWN model differs from the space's — exactly the constant trap.
      provider = fake_provider(name: 'openai', model: 'text-embedding-3-small')

      described_class.new(organisation: organisation, metered: true, provider: provider, target_space: space).call

      row = ContentEmbedding.find_by(embeddable_id: fragment.id)
      expect(row.embedding_model).to eq('text-embedding-ada-002')
      expect(provider).to have_received(:embed_batch_with_usage).with(hash_including(model: 'text-embedding-ada-002'))
    end

    # [T2, review 2026-08-01] Every other example here injects `provider:`, so the branch
    # that builds the provider from the SPACE's own credential snapshot never ran — the
    # B2 roll-back path was untested in the reindexer, and deleting it left the suite
    # green.
    it 'builds its provider from the SPACE credential snapshot when none is injected' do
      space = create(:embedding_space, :byok, organisation: organisation,
                                              embedding_model: 'bge-1536',
                                              access_token: 'sk-space-snapshot')
      create(:fragment, :for_ticket, organisation: organisation)
      snapshot_provider = fake_provider(name: 'openai_compatible', model: 'bge-1536')
      allow(Lalabase::Llm::Factory).to receive(:for_embedding_space).and_return(snapshot_provider)
      allow(Lalabase::Llm::Factory).to receive(:for_embeddings)

      described_class.new(organisation: organisation, metered: true, target_space: space).call

      expect(Lalabase::Llm::Factory).to have_received(:for_embedding_space).with(space, organisation)
      # ...and NOT through the configured path, which would use the org's current
      # (already overwritten) BYOK columns — the exact failure B2 exists to prevent.
      expect(Lalabase::Llm::Factory).not_to have_received(:for_embeddings)
    end

    # [R4, review 2026-08-01] Cross-tenant guard: a foreign space would contribute its
    # credentials and stamp its triple onto THIS org's rows.
    it 'refuses a target_space belonging to another organisation' do
      other = create(:organisation, name: 'Other', subdomain: 'other-reindex')
      foreign = ActsAsTenant.with_tenant(other) { create(:embedding_space, organisation: other) }

      expect { described_class.new(organisation: organisation, metered: true, target_space: foreign) }
        .to raise_error(ArgumentError, /does not belong to organisation/)
    end
  end
end
