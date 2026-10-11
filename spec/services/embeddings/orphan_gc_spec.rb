# frozen_string_literal: true

require 'rails_helper'

# What: Embeddings::OrphanGc — the daily two-sweep reclamation of embedding rows
#       whose owner is gone (embedding v2 PR 3, §3.2).
# Why:  Sweep 1 clears sidecar rows orphaned by callback-free parent deletes;
#       Sweep 2 clears fragments (and their sidecar) left behind by the EPS
#       destroy-mid-run race. A LIVE row must NEVER be touched. The default run is
#       GLOBAL (organisation: nil → without_tenant, spanning every org and logging
#       per-org for GDPR attribution); the org-scoped path (organisation: org) is the
#       special case the rake task + status probe use. Per-type isolation means one
#       broken sweep type neither aborts the others nor the run. Both source maps are
#       reflection-pinned so a new owner type breaks the spec instead of leaking PII.
RSpec.describe Embeddings::OrphanGc do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:repo) { create(:project_repository, organisation: organisation, project: project) }
  let(:user) { create(:user) }
  let(:vector) { Array.new(1536, 0.5) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  describe 'sweep 1 (sidecar orphans)' do
    it 'reclaims sidecar rows whose embeddable is gone and never a live one' do
      # Orphans: parent-style bulk delete_all is callback-free, so the sidecar survives.
      dead_fragment = create(:fragment, :for_ticket, organisation: organisation)
      create(:content_embedding, organisation: organisation, embeddable: dead_fragment)
      Fragment.where(id: dead_fragment.id).delete_all

      dead_symbol = create(:code_symbol, organisation: organisation, project_repository: repo)
      create(:content_embedding, organisation: organisation, embeddable: dead_symbol)
      CodeSymbol.where(id: dead_symbol.id).delete_all

      # Positive control: a live embeddable's sidecar row must remain untouched.
      live_fragment = create(:fragment, :for_ticket, organisation: organisation)
      live_row = create(:content_embedding, organisation: organisation, embeddable: live_fragment)

      result = described_class.call(organisation: organisation)

      expect(ContentEmbedding.where(embeddable_type: 'Fragment', embeddable_id: dead_fragment.id)).to be_empty
      expect(ContentEmbedding.where(embeddable_type: 'CodeSymbol', embeddable_id: dead_symbol.id)).to be_empty
      expect(ContentEmbedding.exists?(live_row.id)).to be(true)
      expect(result.orphan_embeddings).to eq(2)
    end
  end

  describe 'sweep 2 (fragment orphans — the EPS destroy-mid-run net)' do
    it 'reclaims a fragment whose fragmentable is gone AND its sidecar; spares a live-owner one' do
      meeting = create(:meeting, project: project, organisation: organisation, creator: user, create_embeddings: true)
      orphan_frag = create(:fragment, fragmentable: meeting, organisation: organisation)
      create(:content_embedding, organisation: organisation, embeddable: orphan_frag)
      meeting.delete # bypasses callbacks — the exact race end-state (fragment + sidecar survive)

      live_meeting = create(:meeting, project: project, organisation: organisation, creator: user)
      live_frag = create(:fragment, fragmentable: live_meeting, organisation: organisation)
      live_row = create(:content_embedding, organisation: organisation, embeddable: live_frag)

      result = described_class.call(organisation: organisation)

      expect(Fragment.where(id: orphan_frag.id)).to be_empty
      expect(ContentEmbedding.where(embeddable_type: 'Fragment', embeddable_id: orphan_frag.id)).to be_empty
      expect(Fragment.exists?(live_frag.id)).to be(true)
      expect(ContentEmbedding.exists?(live_row.id)).to be(true)
      expect(result.orphan_fragments).to eq(1)
    end
  end

  describe 'organisation scoping' do
    it 'leaves another org’s orphans untouched during an org-scoped run' do
      frag_a = create(:fragment, :for_ticket, organisation: organisation)
      create(:content_embedding, organisation: organisation, embeddable: frag_a)
      Fragment.where(id: frag_a.id).delete_all

      org_b = create(:organisation, name: 'B', subdomain: 'orgb')
      proj_b = create(:project, organisation: org_b)
      row_b = ActsAsTenant.with_tenant(org_b) do
        frag = create(:fragment, fragmentable: create(:ticket, project: proj_b, organisation: org_b),
                                 organisation: org_b)
        row = create(:content_embedding, organisation: org_b, embeddable: frag)
        Fragment.where(id: frag.id).delete_all
        row
      end

      described_class.call(organisation: organisation) # org A only

      expect(ContentEmbedding.unscoped.where(embeddable_type: 'Fragment', embeddable_id: frag_a.id)).to be_empty
      expect(ContentEmbedding.unscoped.exists?(row_b.id)).to be(true)
    end
  end

  describe 'dry_run' do
    it 'counts orphans without deleting; the counts equal a real run (no silent caps)' do
      frag = create(:fragment, :for_ticket, organisation: organisation)
      create(:content_embedding, organisation: organisation, embeddable: frag)
      Fragment.where(id: frag.id).delete_all

      dry = described_class.call(organisation: organisation, dry_run: true)
      expect(dry.orphan_embeddings).to eq(1)
      expect(ContentEmbedding.where(embeddable_type: 'Fragment', embeddable_id: frag.id)).not_to be_empty

      real = described_class.call(organisation: organisation)
      expect(real.orphan_embeddings).to eq(dry.orphan_embeddings)
      expect(ContentEmbedding.where(embeddable_type: 'Fragment', embeddable_id: frag.id)).to be_empty
    end

    # Regression guard for the DRY_RUN=1 arming step: sweep 2 (fragment orphans) must
    # NOT delete the fragment OR its sidecar in dry_run — previously only sweep 1 was
    # covered, so a dry-run that wrongly purged fragments could slip through.
    it 'sweep 2: counts fragment orphans without deleting the fragment or its sidecar' do
      meeting = create(:meeting, project: project, organisation: organisation, creator: user, create_embeddings: true)
      orphan_frag = create(:fragment, fragmentable: meeting, organisation: organisation)
      sidecar = create(:content_embedding, organisation: organisation, embeddable: orphan_frag)
      meeting.delete # bypasses callbacks — fragment + sidecar survive (the race end-state)

      result = described_class.call(organisation: organisation, dry_run: true)

      expect(result.orphan_fragments).to eq(1)
      expect(Fragment.exists?(orphan_frag.id)).to be(true)
      expect(ContentEmbedding.exists?(sidecar.id)).to be(true)
    end
  end

  describe 'global mode (organisation: nil)' do
    it 'sweeps orphans across EVERY org in one run and logs reclaimed counts per org' do
      # Org A orphan (ambient tenant).
      frag_a = create(:fragment, :for_ticket, organisation: organisation)
      create(:content_embedding, organisation: organisation, embeddable: frag_a)
      Fragment.where(id: frag_a.id).delete_all

      # Org B orphan (a different tenant the global sweep must also reach).
      org_b = create(:organisation, name: 'B', subdomain: 'orgb')
      proj_b = create(:project, organisation: org_b)
      row_b = ActsAsTenant.with_tenant(org_b) do
        frag = create(:fragment, fragmentable: create(:ticket, project: proj_b, organisation: org_b),
                                 organisation: org_b)
        row = create(:content_embedding, organisation: org_b, embeddable: frag)
        Fragment.where(id: frag.id).delete_all
        row
      end

      ActsAsTenant.current_tenant = nil # prove the global run needs NO ambient tenant
      allow(Rails.logger).to receive(:info)

      result = described_class.call # organisation: nil → without_tenant

      expect(ContentEmbedding.unscoped.where(embeddable_type: 'Fragment', embeddable_id: frag_a.id)).to be_empty
      expect(ContentEmbedding.unscoped.exists?(row_b.id)).to be(false)
      expect(result.orphan_embeddings).to eq(2)
      # Per-org attribution (GDPR): neither org's count collapses into an anonymous total.
      expect(Rails.logger).to have_received(:info).with(/org=#{organisation.id} .*reclaimed=1/)
      expect(Rails.logger).to have_received(:info).with(/org=#{org_b.id} .*reclaimed=1/)
    end
  end

  describe 'per-type isolation (#2)' do
    it 'isolates a broken sweep type, reports it with its class, and still sweeps the healthy ones' do
      dead_symbol = create(:code_symbol, organisation: organisation, project_repository: repo)
      create(:content_embedding, organisation: organisation, embeddable: dead_symbol)
      CodeSymbol.where(id: dead_symbol.id).delete_all

      # A bogus fragmentable type whose constantize raises — the run must survive it
      # and still reclaim the (healthy) CodeSymbol sidecar orphan in the other sweep.
      stub_const('Embeddings::OrphanGc::FRAGMENTABLE_SOURCES',
                 described_class::FRAGMENTABLE_SOURCES + ['NoSuchOwnerModel'])
      allow(Rails.logger).to receive(:error)

      result = described_class.call(organisation: organisation)

      expect(ContentEmbedding.where(embeddable_type: 'CodeSymbol', embeddable_id: dead_symbol.id)).to be_empty
      expect(result.errors).to eq(1)
      expect(Rails.logger).to have_received(:error).with(/sweep=fragment type=NoSuchOwnerModel FAILED: NameError/)
    end
  end

  describe 'defensive: unknown types' do
    it 'counts and warns about an unknown fragmentable_type without deleting it' do
      unknown_id = SecureRandom.uuid
      Fragment.insert!({ id: unknown_id, fragmentable_type: 'Widget', fragmentable_id: SecureRandom.uuid,
                         organisation_id: organisation.id, plain_text_content: 'x', version_token: SecureRandom.hex(8),
                         created_at: Time.current, updated_at: Time.current })
      allow(Rails.logger).to receive(:warn)

      described_class.call(organisation: organisation)

      expect(Rails.logger).to have_received(:warn).with(/UNKNOWN fragmentable_type=Widget/)
      expect(Fragment.exists?(unknown_id)).to be(true)
    end

    # The embeddable_type branch of warn_unknown_types (the fragmentable_type branch
    # is covered above) — a sidecar row of an unregistered embeddable is warned, never
    # swept.
    it 'counts and warns about an unknown embeddable_type without deleting it' do
      row = create(:content_embedding, organisation: organisation,
                                       embeddable: create(:fragment, :for_ticket, organisation: organisation))
      row.update_column(:embeddable_type, 'Widget') # now outside EMBEDDABLE_SOURCES
      allow(Rails.logger).to receive(:warn)

      described_class.call(organisation: organisation)

      expect(Rails.logger).to have_received(:warn).with(/UNKNOWN embeddable_type=Widget/)
      expect(ContentEmbedding.exists?(row.id)).to be(true)
    end
  end

  # Sweep 3 (embedding v2 PR 6b). What makes these worth their runtime is the PAIRING:
  # every protection has a control case in which the very same setup DOES get collected,
  # so a rule that silently stopped applying cannot pass as "protected".
  #
  # The factory stub answers ONLY for space: :configured — an accidental :active call
  # RAISES instead of being absorbed. A stub answering both the same way is exactly the
  # structural hole that let nine mutations through in earlier rounds
  # (spec/services/embeddings/space_routing_guard_spec.rb).
  describe 'sweep 3 (retention — whole vector spaces beyond the org limit)' do
    let(:logger) { instance_spy(Logger) }

    # ONE corpus, rows in SEVERAL spaces — what an org actually looks like after a
    # switch: each record carries a row per space it was embedded into. Building a
    # separate fragment per space would be both unrealistic and pure Prosopite noise
    # from the factory chain.
    let(:corpus) do
      Prosopite.pause { Array.new(3) { create(:fragment, :for_ticket, organisation: organisation) } }
    end

    # Spaces differ by MODEL, not dims: the unique index covers the whole triple, and
    # dims would run out after four.
    def space_with_rows(model:, retired_at: nil, rows: 1)
      space = nil
      Prosopite.pause do
        space = create(:embedding_space, organisation: organisation, embedding_model: model,
                                         retired_at: retired_at)
        corpus.first(rows).each do |fragment|
          create(:content_embedding, organisation: organisation, embeddable: fragment,
                                     embedding: Array.new(1536, 0.01), **space.triple)
        end
      end
      space
    end

    def configure(triple)
      allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
        .with(anything, space: :configured).and_return(triple)
    end

    def activate(space)
      organisation.update_column(:active_embedding_space_id, space.id)
    end

    def sweep(dry_run: false, retention_dry_run: dry_run)
      described_class.call(organisation: organisation, dry_run: dry_run,
                           retention_dry_run: retention_dry_run, logger: logger)
    end

    describe 'the active space is never a candidate' do
      # The configured triple deliberately names a space the org does NOT hold — an
      # operator who changed the configuration but has not started the build yet.
      #
      # This matters for what the example proves. Configured = active (the steady
      # state) would have the build exception shielding the active space as well, and
      # removing the active-space protection then changes NOTHING: the example passes
      # against the mutation it exists to catch. Verified by mutation, not assumed.
      let(:unbuilt_configuration) do
        { embedding_provider: 'openai', embedding_model: 'planned-model', embedding_dims: 1536 }
      end

      it 'keeps the active space and collects every other one at limit = 1' do
        active = space_with_rows(model: 'active-model')
        old_a  = space_with_rows(model: 'old-a', retired_at: 2.days.ago)
        old_b  = space_with_rows(model: 'old-b', retired_at: 1.day.ago)
        activate(active)
        organisation.update!(embedding_retention_limit: 1)
        configure(unbuilt_configuration)

        result = sweep

        expect(EmbeddingSpace.exists?(active.id)).to be(true)
        expect(active.content_embeddings.count).to eq(1)
        expect(EmbeddingSpace.where(id: [old_a.id, old_b.id])).to be_empty
        expect(result.retention_spaces).to eq(2)
        expect(result.retention_embeddings).to eq(2)
      end

      # Control for the case above: the same limit DOES take a space once it is no
      # longer the active one, so "active survived" is a protection and not just an
      # inert sweep.
      it 'collects a former space that is no longer active, at the same limit' do
        active = space_with_rows(model: 'active-model')
        stale_space = space_with_rows(model: 'was-active', retired_at: 1.day.ago)
        activate(active)
        organisation.update!(embedding_retention_limit: 1)
        configure(unbuilt_configuration)

        sweep

        expect(EmbeddingSpace.exists?(stale_space.id)).to be(false)
        expect(ContentEmbedding.where(embedding_model: 'was-active')).to be_empty
      end
    end

    describe 'a space under construction' do
      it 'is never collected, not even at limit = 1' do
        active = space_with_rows(model: 'active-model')
        building = space_with_rows(model: 'target-model')
        activate(active)
        organisation.update!(embedding_retention_limit: 1)
        configure(building.triple) # configured but not active = the build in progress

        result = sweep

        expect(EmbeddingSpace.exists?(building.id)).to be(true)
        expect(result.retention_spaces).to eq(0)
      end

      # THE m3 assertion, and the one this protection actually exists for. The build
      # space must leave the candidate list BEFORE the keep list is taken; taken after,
      # it occupies the single retained slot and the genuine old space — the one the A/B
      # comparison is against — is evicted instead.
      #
      # The build space here carries a retired_at (it served before: the operator is
      # preparing a switch BACK to it), because that is the case where the ordering
      # alone does not already save the old space.
      it 'does not consume a retained slot' do
        active = space_with_rows(model: 'active-model')
        old = space_with_rows(model: 'old-model', retired_at: 10.days.ago)
        building = space_with_rows(model: 'target-model', retired_at: 1.day.ago)
        activate(active)
        organisation.update!(embedding_retention_limit: 2)
        configure(building.triple)

        result = sweep

        expect(EmbeddingSpace.exists?(old.id)).to be(true)
        expect(EmbeddingSpace.exists?(building.id)).to be(true)
        expect(result.retention_spaces).to eq(0)
      end

      # Control: the identical shape WITHOUT a build (configured = active) does collect
      # the third space. Without this, "nothing collected" above could equally mean the
      # sweep never ran at all.
      it 'collects the same third space once no build is in progress' do
        active = space_with_rows(model: 'active-model')
        old = space_with_rows(model: 'old-model', retired_at: 10.days.ago)
        newer = space_with_rows(model: 'newer-model', retired_at: 1.day.ago)
        activate(active)
        organisation.update!(embedding_retention_limit: 2)
        configure(active.triple)

        result = sweep

        expect(EmbeddingSpace.exists?(newer.id)).to be(true)
        expect(EmbeddingSpace.exists?(old.id)).to be(false)
        expect(result.retention_spaces).to eq(1)
      end
    end

    # Which of two candidates survives is a real decision, and created_at gets it wrong
    # after a roll-back: the space rolled back FROM is the newest, the space rolled back
    # TO is the one worth keeping.
    describe 'ordering (by retirement recency, never by creation)' do
      it 'keeps the most recently RETIRED space, not the most recently created' do
        active = space_with_rows(model: 'active-model')
        # Created last, retired long ago — created_at ordering would keep this one.
        rolled_back_from = space_with_rows(model: 'rejected-model', retired_at: 30.days.ago)
        # Created first, retired yesterday: the space that actually served last.
        served_last = space_with_rows(model: 'proven-model', retired_at: 1.day.ago)
        rolled_back_from.update_column(:created_at, 1.hour.ago)
        served_last.update_column(:created_at, 90.days.ago)
        activate(active)
        organisation.update!(embedding_retention_limit: 2)
        configure(active.triple)

        sweep

        expect(EmbeddingSpace.exists?(served_last.id)).to be(true)
        expect(EmbeddingSpace.exists?(rolled_back_from.id)).to be(false)
      end

      it 'collects a space that NEVER served before one that did (NULLS LAST)' do
        active = space_with_rows(model: 'active-model')
        never_served = space_with_rows(model: 'abandoned-build') # retired_at nil
        displaced = space_with_rows(model: 'former-model', retired_at: 30.days.ago)
        activate(active)
        organisation.update!(embedding_retention_limit: 2)
        configure(active.triple)

        sweep

        expect(EmbeddingSpace.exists?(displaced.id)).to be(true)
        expect(EmbeddingSpace.exists?(never_served.id)).to be(false)
      end
    end

    describe 'the limit boundary' do
      # n−1 / n / n+1 held spaces against limit = 2.
      [[1, 0], [2, 0], [3, 1]].each do |held, collected|
        it "collects #{collected} space(s) when the org holds #{held} at limit 2" do
          active = space_with_rows(model: 'active-model')
          (held - 1).times { |i| space_with_rows(model: "old-#{i}", retired_at: (i + 1).days.ago) }
          activate(active)
          organisation.update!(embedding_retention_limit: 2)
          configure(active.triple)

          expect(sweep.retention_spaces).to eq(collected)
        end
      end
    end

    it 'deletes the sidecar rows AND the embedding_spaces row' do
      active = space_with_rows(model: 'active-model')
      doomed = space_with_rows(model: 'doomed-model', retired_at: 1.day.ago, rows: 3)
      activate(active)
      organisation.update!(embedding_retention_limit: 1)
      configure(active.triple)

      result = sweep

      expect(ContentEmbedding.where(embedding_model: 'doomed-model')).to be_empty
      expect(EmbeddingSpace.exists?(doomed.id)).to be(false)
      expect(result.retention_embeddings).to eq(3)
    end

    it 'counts without deleting in dry_run' do
      active = space_with_rows(model: 'active-model')
      doomed = space_with_rows(model: 'doomed-model', retired_at: 1.day.ago, rows: 2)
      activate(active)
      organisation.update!(embedding_retention_limit: 1)
      configure(active.triple)

      result = sweep(dry_run: true)

      expect(EmbeddingSpace.exists?(doomed.id)).to be(true)
      expect(doomed.content_embeddings.count).to eq(2)
      # Identical numbers to a real run — "no silent caps".
      expect(result.retention_spaces).to eq(1)
      expect(result.retention_embeddings).to eq(2)
    end

    it 'logs the collected count per org and space (GDPR attribution)' do
      active = space_with_rows(model: 'active-model')
      space_with_rows(model: 'doomed-model', retired_at: 1.day.ago, rows: 2)
      activate(active)
      organisation.update!(embedding_retention_limit: 1)
      configure(active.triple)

      sweep

      expect(logger).to have_received(:info)
        .with(%r{org=#{organisation.id} sweep=retention space=openai/doomed-model/1536 collected=2})
    end

    # Fail-SAFE: without the configured triple the sweep cannot tell a build from an
    # abandoned space, and a guess would collect one that is being built right now.
    it 'collects nothing for an org whose configured space does not resolve' do
      active = space_with_rows(model: 'active-model')
      doomed = space_with_rows(model: 'doomed-model', retired_at: 1.day.ago)
      activate(active)
      organisation.update!(embedding_retention_limit: 1)
      allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
        .with(anything, space: :configured)
        .and_raise(Lalabase::Llm::Factory::MissingCredentialError, 'no credential')

      result = sweep

      expect(EmbeddingSpace.exists?(doomed.id)).to be(true)
      expect(result.retention_spaces).to eq(0)
      # The skip is COUNTED, not only logged (review F5): spaces=0 alone cannot be
      # told apart from "nothing to collect", so a fleet-wide resolution failure
      # would otherwise be a permanent silent no-op.
      expect(result.retention_skipped).to eq(1)
      expect(logger).to have_received(:warn).with(/sweep=retention SKIPPED/)
    end

    it 'leaves another organisation alone' do
      other = create(:organisation)
      # with_tenant, not just `organisation: other`: acts_as_tenant stamps the AMBIENT
      # tenant on create, so building the foreign org's spaces under this example's
      # tenant would silently file them under THIS org — and the isolation this example
      # claims to prove would never be exercised (space_alignment_spec.rb:40 precedent).
      other_old = ActsAsTenant.with_tenant(other) do
        Prosopite.pause do
          other_active = create(:embedding_space, organisation: other, embedding_model: 'other-active')
          other.update_column(:active_embedding_space_id, other_active.id)
          other.update!(embedding_retention_limit: 1)
          create(:embedding_space, organisation: other, embedding_model: 'other-old',
                                   retired_at: 1.day.ago)
        end
      end

      active = space_with_rows(model: 'active-model')
      doomed = space_with_rows(model: 'doomed-model', retired_at: 1.day.ago)
      activate(active)
      organisation.update!(embedding_retention_limit: 1)
      configure(active.triple)

      sweep

      expect(EmbeddingSpace.exists?(doomed.id)).to be(false)
      # without_tenant on the ASSERTION too: EmbeddingSpace is tenant-scoped, so a bare
      # exists? under this example's tenant answers false whether the sweep spared the
      # foreign space or deleted it — the test would pass for the wrong reason.
      expect(ActsAsTenant.without_tenant { EmbeddingSpace.exists?(other_old.id) }).to be(true)
    end

    # The GLOBAL sweep is where the explicit organisation_id predicate earns its keep.
    # Org-scoped, acts_as_tenant would cover for a missing filter and the isolation
    # above would pass either way; under without_tenant nothing does. Each org must be
    # judged against ITS OWN spaces and ITS OWN limit.
    it 'judges every org against its own spaces and limit in the global sweep' do
      other = create(:organisation)
      other_spaces = ActsAsTenant.with_tenant(other) do
        Prosopite.pause do
          active = create(:embedding_space, organisation: other, embedding_model: 'b-active')
          other.update_column(:active_embedding_space_id, active.id)
          other.update!(embedding_retention_limit: 2) # keeps its one old space
          [active, create(:embedding_space, organisation: other, embedding_model: 'b-old',
                                            retired_at: 1.day.ago)]
        end
      end

      active = space_with_rows(model: 'a-active')
      old_a = space_with_rows(model: 'a-old-1', retired_at: 1.day.ago)
      old_b = space_with_rows(model: 'a-old-2', retired_at: 2.days.ago)
      activate(active)
      organisation.update!(embedding_retention_limit: 1) # keeps nothing but the active one

      # The factory answers PER ORG, so a sweep reading the wrong org's configuration
      # changes the outcome instead of being absorbed by a one-size stub.
      allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
        .with(having_attributes(id: organisation.id), space: :configured).and_return(active.triple)
      allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
        .with(having_attributes(id: other.id), space: :configured).and_return(other_spaces.first.triple)

      result = ActsAsTenant.without_tenant { described_class.call(dry_run: false, logger: logger) }

      expect(result.retention_spaces).to eq(2)
      ActsAsTenant.without_tenant do
        expect(EmbeddingSpace.where(id: [old_a.id, old_b.id])).to be_empty
        expect(EmbeddingSpace.where(id: other_spaces.map(&:id)).count).to eq(2)
      end
    end

    # The third row type: record alive (no orphan), no space row holds its triple (no
    # retention candidate). Nothing reclaims these, and the honest move is to say so
    # rather than delete on the suspicion — the same triple is what a fresh target looks
    # like before embeddings:build_target registers it.
    it 'never touches rows whose triple has no space row, and reports them' do
      active = space_with_rows(model: 'active-model')
      activate(active)
      configure(active.triple)
      fragment = create(:fragment, :for_ticket, organisation: organisation)
      unregistered = create(:content_embedding, organisation: organisation, embeddable: fragment,
                                                embedding: Array.new(1536, 0.01),
                                                embedding_provider: 'openai',
                                                embedding_model: 'text-embedding-ada-002',
                                                embedding_dims: 1536)

      sweep

      expect(ContentEmbedding.exists?(unregistered.id)).to be(true)
      expect(logger).to have_received(:warn)
        .with(%r{UNREGISTERED space openai/text-embedding-ada-002/1536 rows=1})
    end

    # Fork F2, verified where it lives (review C3). Every example above drives both
    # flags through ONE `dry_run:` value, so they never diverge — swapping
    # @retention_dry_run for @dry_run in collect_space stayed green across the whole
    # file. These two are the divergent pairs, and either alone kills that swap. The
    # first is the exact production configuration of the first armed nights.
    describe 'the two switches are independent (fork F2, at the service level)' do
      it 'deletes orphans but keeps the doomed space when only the orphan sweep is armed' do
        active = space_with_rows(model: 'active-model')
        doomed = space_with_rows(model: 'doomed-model', retired_at: 1.day.ago, rows: 2)
        activate(active)
        organisation.update!(embedding_retention_limit: 1)
        configure(active.triple)
        corpus.first.delete # callback-free — its sidecar rows in BOTH spaces become orphans

        result = sweep(dry_run: false, retention_dry_run: true)

        expect(result.orphan_embeddings).to eq(2)
        expect(EmbeddingSpace.exists?(doomed.id)).to be(true)
        # The doomed space kept its surviving row: retention only counted.
        expect(doomed.content_embeddings.count).to eq(1)
        expect(result.retention_spaces).to eq(1)
      end

      it 'collects the doomed space but keeps orphans when only retention is armed' do
        active = space_with_rows(model: 'active-model')
        doomed = space_with_rows(model: 'doomed-model', retired_at: 1.day.ago)
        activate(active)
        organisation.update!(embedding_retention_limit: 1)
        configure(active.triple)
        corpus.first.delete # the active space's row for it is now an orphan

        result = sweep(dry_run: true, retention_dry_run: false)

        expect(EmbeddingSpace.exists?(doomed.id)).to be(false)
        # The orphan row in the ACTIVE space survived: that sweep only counted.
        expect(ContentEmbedding.where(embedding_model: 'active-model').count).to eq(1)
        expect(result.orphan_embeddings).to eq(2)
      end
    end

    # Plan sheet §5 spec 10 — it fell out between the plan table and the DoD; restored
    # by the review. One broken org must not cost the others their cleanup. The failure
    # is injected at the DECISION boundary on purpose (configured_triple's own rescue
    # would swallow anything raised beneath it), and it hits whichever org find_each
    # yields FIRST — UUID PKs make the order random, and only "the failure came before
    # the survivor" proves isolation. The loop's rescue is the contract under test.
    it 'sweeps the remaining org and tallies the error when the first org fails (per-org isolation)' do
      other = create(:organisation)
      other_old = ActsAsTenant.with_tenant(other) do
        Prosopite.pause do
          other_active = create(:embedding_space, organisation: other, embedding_model: 'b-active')
          other.update_column(:active_embedding_space_id, other_active.id)
          other.update!(embedding_retention_limit: 1)
          allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
            .with(having_attributes(id: other.id), space: :configured)
            .and_return(other_active.triple)
          create(:embedding_space, organisation: other, embedding_model: 'b-old', retired_at: 1.day.ago)
        end
      end
      active = space_with_rows(model: 'active-model')
      doomed = space_with_rows(model: 'doomed-model', retired_at: 1.day.ago)
      activate(active)
      organisation.update!(embedding_retention_limit: 1)
      allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
        .with(having_attributes(id: organisation.id), space: :configured).and_return(active.triple)

      gc = described_class.new(dry_run: false, logger: logger)
      broken_id = nil
      allow(gc).to receive(:collect_spaces_for).and_wrap_original do |m, org|
        broken_id ||= org.id
        raise ActiveRecord::StatementInvalid, 'boom' if org.id == broken_id

        m.call(org)
      end

      result = ActsAsTenant.without_tenant { gc.call }

      # Whichever org failed, the OTHER one's doomed space was still collected.
      ActsAsTenant.without_tenant do
        expect(EmbeddingSpace.where(id: [doomed.id, other_old.id]).count).to eq(1)
      end
      expect(result.errors).to eq(1)
      expect(logger).to have_received(:error)
        .with(/sweep=retention org=#{broken_id} FAILED: ActiveRecord::StatementInvalid/)
    end

    # Review C2 — the last-moment re-checks. These pin the MECHANICS (the decision is
    # re-asked from fresh reads, the registry delete re-asks under the org row lock);
    # a genuine two-connection race test is not something this suite establishes, the
    # same honesty stance as the R5 examples in flip_embedding_model_spec.
    describe 'the last-moment re-checks (C2 — mechanics, not a race proof)' do
      it 'spares a space untouched when it became active between decision and delete' do
        active = space_with_rows(model: 'active-model')
        doomed = space_with_rows(model: 'doomed-model', retired_at: 1.day.ago)
        activate(active)
        organisation.update!(embedding_retention_limit: 1)
        configure(active.triple)

        gc = described_class.new(organisation: organisation, logger: logger)
        allow(gc).to receive(:still_doomed?).and_wrap_original do |m, space|
          organisation.update_column(:active_embedding_space_id, space.id)
          m.call(space)
        end

        gc.call

        expect(EmbeddingSpace.exists?(doomed.id)).to be(true)
        expect(doomed.content_embeddings.count).to eq(1)
        expect(logger).to have_received(:info).with(/SPARED before delete/)
      end

      it 'spares the registry row when the space became active mid-delete, reporting removed rows' do
        active = space_with_rows(model: 'active-model')
        doomed = space_with_rows(model: 'doomed-model', retired_at: 1.day.ago, rows: 2)
        activate(active)
        organisation.update!(embedding_retention_limit: 1)
        configure(active.triple)

        gc = described_class.new(organisation: organisation, logger: logger)
        allow(gc).to receive(:delete_in_batches).and_wrap_original do |m, rows|
          organisation.update_column(:active_embedding_space_id, doomed.id) if rows.to_sql.include?('doomed-model')
          m.call(rows)
        end

        result = gc.call

        expect(EmbeddingSpace.exists?(doomed.id)).to be(true)
        expect(doomed.content_embeddings.count).to eq(0)
        # Spared spaces do not count as collected — but rows the spare came too late
        # for are reported honestly, not hidden (GDPR attribution).
        expect(result.retention_spaces).to eq(0)
        expect(result.retention_embeddings).to eq(2)
        expect(logger).to have_received(:warn).with(/SPARED at destroy/)
      end
    end
  end

  # A new fragmentable/embeddable owner must be added to the maps DELIBERATELY — the
  # reflection pins break the suite the moment one is declared but not registered,
  # rather than letting its orphans slip past the GC.
  describe 'source maps stay in sync with the model reflections' do
    before { Rails.application.eager_load! }

    it 'FRAGMENTABLE_SOURCES covers exactly has_many :fragments, as: :fragmentable' do
      owners = ApplicationRecord.descendants.select do |model|
        model.reflect_on_all_associations(:has_many)
             .any? { |assoc| assoc.name == :fragments && assoc.options[:as] == :fragmentable }
      end.map(&:name)

      expect(described_class::FRAGMENTABLE_SOURCES).to match_array(owners)
    end

    it 'EMBEDDABLE_SOURCES covers exactly has_many :content_embeddings, as: :embeddable' do
      owners = ApplicationRecord.descendants.select do |model|
        model.reflect_on_all_associations(:has_many)
             .any? { |assoc| assoc.name == :content_embeddings && assoc.options[:as] == :embeddable }
      end.map(&:name)

      expect(described_class::EMBEDDABLE_SOURCES).to match_array(owners)
    end
  end
end
