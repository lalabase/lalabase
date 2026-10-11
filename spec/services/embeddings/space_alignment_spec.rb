# frozen_string_literal: true

require 'rails_helper'

# What: Embeddings::SpaceAlignment — compares the provenance triples stamped on an
#       org's content_embeddings rows with the vector space the READ path
#       (Embeddings::NearestNeighbors → Lalabase::Llm::Factory.embedding_space_for)
#       actually queries.
# Why:  A divergence between the two is INVISIBLE in production — the read seam
#       filters on the full triple, so a stale corpus yields zero hits without any
#       error (incident 2026-07-30: 8385 of 8389 rows stamped ada-002 while the
#       reader resolved text-embedding-3-small). The existing completeness probe
#       cannot see it, because it only asks whether a sidecar row EXISTS.
# Pattern: sidecar_backfill_spec — tenant set BEFORE model creation.
RSpec.describe Embeddings::SpaceAlignment do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:repo) { create(:project_repository, organisation: organisation, project: project) }
  let(:active_space) { EmbeddingSidecarHelpers::DEFAULT_EMBEDDING_SPACE }
  # The space of the incident: same provider and dimension, OLD model. Nothing but
  # the model tells the two apart — which is exactly why it went unnoticed.
  let(:legacy_space) do
    { embedding_provider: 'openai', embedding_model: 'text-embedding-ada-002', embedding_dims: 1536 }
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def result
    described_class.call(organisation: organisation)
  end

  # A sidecar row in an explicit space. The vector length must equal embedding_dims
  # (CHECK content_embeddings_dims_check), so the dimension is honoured here too —
  # a 768 row is a REAL 768 row, not a mislabelled 1536 one.
  #
  # `indexed:` defaults to true like every write path today; the examples that pass
  # false model what PR 6 (retirement) starts writing.
  def sidecar_row(record, space, org: organisation, indexed: true)
    ActsAsTenant.with_tenant(org) do
      create(:content_embedding, organisation: org, embeddable: record, indexed: indexed,
                                 embedding: Array.new(space[:embedding_dims], 0.001), **space)
    end
  end

  def code_symbol(org: organisation, repository: repo)
    create(:code_symbol, organisation: org, project_repository: repository)
  end

  def fragment(org: organisation)
    create(:fragment, :for_ticket, organisation: org)
  end

  let(:foreign_org) { create(:organisation, name: 'Other', subdomain: 'other') }
  let(:foreign_symbol) do
    project = create(:project, organisation: foreign_org)
    code_symbol(org: foreign_org, repository: create(:project_repository, organisation: foreign_org, project: project))
  end

  describe 'with a resolvable read space' do
    before { stub_default_embedding_space }

    context 'when every row carries the resolved triple' do
      it 'reports ALIGNED with the full row count in the active space' do
        sidecar_row(code_symbol, active_space)
        sidecar_row(fragment, active_space)

        expect(result).to have_attributes(
          status: :aligned, aligned?: true, resolved?: true,
          severity: :ok, blocking?: false,
          total_count: 2, aligned_count: 2, misaligned_count: 0,
          stranded_count: 0, stale_count: 0, orphan_count: 0,
          misaligned_groups: [], stranded_groups: [], orphan_groups: [], error: nil
        )
      end

      it 'names the resolved space and derives its label from the SAME triple' do
        expect(result).to have_attributes(
          space: active_space, space_label: 'openai/text-embedding-3-small/1536'
        )
      end
    end

    it 'reports ALIGNED (vacuously) for an org without any sidecar rows' do
      expect(result).to have_attributes(status: :aligned, total_count: 0, groups: [])
    end

    context 'when the rows rest in an older model space (the incident)' do
      it 'reports MISALIGNED, counts them as STRANDED and names where they sit' do
        sidecar_row(code_symbol, legacy_space)
        sidecar_row(code_symbol, legacy_space)

        expect(result).to have_attributes(
          status: :misaligned, aligned?: false, total_count: 2, aligned_count: 0,
          misaligned_count: 2, stranded_count: 2, stale_count: 0
        )
        expect(result.stranded_groups.map(&:space_label)).to eq(['openai/text-embedding-ada-002/1536'])
      end
    end

    it 'treats a DIMENSION-only divergence as misaligned (the triple, not the pair)' do
      # Same provider AND model, different dimension — the case PR 5 makes routine.
      sidecar_row(code_symbol, active_space.merge(embedding_dims: 768))

      expect(result).to have_attributes(status: :misaligned, misaligned_count: 1, stranded_count: 1)
      expect(result.stranded_groups.map(&:space_label)).to eq(['openai/text-embedding-3-small/768'])
    end

    # THE case that makes this usable as a gate: OrganisationReindexer writes the new
    # space but leaves the old rows behind (retirement only lands in PR 6). A check
    # that failed on those leftovers would stay red after exactly the repair it
    # recommends — so a record that HAS an active row is fine, however many old rows
    # it drags along.
    it 'stays ALIGNED when old rows remain but every record HAS an active row' do
      symbol = code_symbol
      sidecar_row(symbol, active_space)
      sidecar_row(symbol, legacy_space) # same record, two spaces (the unique index allows it)

      expect(result).to have_attributes(
        status: :aligned, aligned?: true,
        total_count: 2, aligned_count: 1, misaligned_count: 1,
        stranded_count: 0, stale_count: 1
      )
    end

    # The reader's THIRD predicate. NearestNeighbors filters on `indexed` next to the
    # triple, so a row in the right space with the flag cleared is just as unreachable
    # as one in the wrong space — counting it as aligned is false green. No writer
    # produces this state today, but the column default is FALSE, symbol_persistence
    # writes via a bare insert_all, and PR 6 (retirement) is the change that starts
    # clearing the flag on purpose.
    describe 'the indexed flag' do
      it 'does NOT count an active-space row with indexed: false as aligned' do
        sidecar_row(code_symbol, active_space, indexed: false)

        expect(result).to have_attributes(
          status: :misaligned, aligned_count: 0, total_count: 1,
          misaligned_count: 1, stranded_count: 1
        )
      end

      it 'labels it as the active space WITH the flag, so the listing is not read as a bug' do
        sidecar_row(code_symbol, active_space, indexed: false)

        expect(result.stranded_groups.map(&:space_label))
          .to eq(['openai/text-embedding-3-small/1536 [indexed=false]'])
      end

      # PR 6's shape: the old row gets retired, the new one carries the read.
      it 'treats a retired row next to a readable one as stale, not stranded' do
        symbol = code_symbol
        sidecar_row(symbol, active_space)
        sidecar_row(symbol, legacy_space, indexed: false)

        expect(result).to have_attributes(status: :aligned, aligned_count: 1, stale_count: 1, stranded_count: 0)
      end
    end

    # Rows whose record was deleted callback-free (`delete_all` — precisely what
    # Embeddings::OrphanGc exists for). The read seam INNER JOINs the embeddable
    # table (M1), so they are structurally invisible to it; the reindexer walks LIVE
    # records, so no reindex can ever touch them. Either verdict would be wrong:
    # stranded reddens the gate forever behind a fix that is a no-op, aligned
    # inflates the healthy count.
    describe 'orphan rows (record already deleted)' do
      it 'files them in their own bucket instead of stranding them' do
        symbol = code_symbol
        sidecar_row(symbol, legacy_space)
        CodeSymbol.where(id: symbol.id).delete_all

        expect(result).to have_attributes(
          status: :aligned, severity: :ok, blocking?: false,
          total_count: 0, stranded_count: 0, misaligned_count: 0, orphan_count: 1
        )
        expect(result.orphan_groups.map(&:space_label)).to eq(['openai/text-embedding-ada-002/1536'])
      end

      it 'does not let an orphan in the ACTIVE space inflate the aligned count either' do
        symbol = code_symbol
        sidecar_row(symbol, active_space)
        CodeSymbol.where(id: symbol.id).delete_all

        expect(result).to have_attributes(total_count: 0, aligned_count: 0, orphan_count: 1)
      end

      it 'still strands a LIVE record while an orphan sits next to it' do
        dead = code_symbol
        sidecar_row(dead, legacy_space)
        CodeSymbol.where(id: dead.id).delete_all
        sidecar_row(fragment, legacy_space)

        expect(result).to have_attributes(
          status: :misaligned, severity: :error, total_count: 1, stranded_count: 1, orphan_count: 1
        )
        expect(result.stranded_groups.map(&:embeddable_type)).to eq(['Fragment'])
      end
    end

    it 'splits a HALF-reindexed corpus: only the records without an active row strand' do
      reindexed = code_symbol
      sidecar_row(reindexed, active_space)
      sidecar_row(reindexed, legacy_space)
      sidecar_row(fragment, legacy_space) # never reindexed → unreachable

      expect(result).to have_attributes(
        status: :misaligned, total_count: 3, aligned_count: 1,
        misaligned_count: 2, stranded_count: 1, stale_count: 1
      )
      expect(result.aligned_groups.map(&:embeddable_type)).to eq(['CodeSymbol'])
      expect(result.stranded_groups.map(&:embeddable_type)).to eq(['Fragment'])
    end

    it 'groups the deviation by embeddable_type AND by triple' do
      sidecar_row(code_symbol, legacy_space)
      sidecar_row(fragment, legacy_space)
      sidecar_row(fragment, active_space.merge(embedding_dims: 768))

      expect(result.misaligned_groups.map { |g| [g.embeddable_type, g.space_label, g.row_count] })
        .to contain_exactly(['CodeSymbol', 'openai/text-embedding-ada-002/1536', 1],
                            ['Fragment', 'openai/text-embedding-3-small/768', 1],
                            ['Fragment', 'openai/text-embedding-ada-002/1536', 1])
    end

    # The tenant boundary is the whole point of a per-org verdict: a foreign org's
    # stale corpus must not redden this org's gate (nor its own be hidden by ours).
    it 'ignores the sidecar rows of another organisation' do
      sidecar_row(foreign_symbol, legacy_space, org: foreign_org)
      sidecar_row(code_symbol, active_space)

      expect(result).to have_attributes(status: :aligned, total_count: 1)
    end

    # The stranded probe runs as raw SQL and therefore outside the tenant scope: a
    # FOREIGN active-space row must not vouch for one of our stranded rows.
    it 'does not let another organisation\'s active row rescue a stranded record' do
      sidecar_row(foreign_symbol, active_space, org: foreign_org)
      sidecar_row(code_symbol, legacy_space)

      expect(result).to have_attributes(status: :misaligned, total_count: 1, stranded_count: 1)
    end

    # Rake runs without an ambient tenant; the counting must not silently depend on
    # one being set by the caller.
    it 'counts without an ambient tenant (own with_tenant wrapping)' do
      sidecar_row(code_symbol, legacy_space)
      ActsAsTenant.current_tenant = nil

      expect(result).to have_attributes(status: :misaligned, total_count: 1)
    end
  end

  # The case that exposes the premise this object was first built on — and that was
  # wrong: "unresolved is the normal state of an AI-disabled org". It is not.
  # Factory.embedding_space_for is deliberately gate-free: it never reads ai_enabled,
  # it resolves a CREDENTIAL. With an active SYSTEM credential (the production state)
  # the space resolves for every org, AI on or off. What hid this was the dev DB with
  # zero active credentials, where everything fell into :unresolved.
  #
  # No stub here on purpose: a stubbed factory can only ever confirm the assumption
  # that was stubbed in.
  describe 'when AI is switched off but a system credential exists' do
    let(:organisation) { create(:organisation, :ai_disabled) }

    before { create(:ai_credential, :active, provider: 'openai') }

    it 'resolves the space for the AI-disabled org (no ai_enabled gate in the resolution)' do
      expect(result).to have_attributes(resolved?: true, space: active_space, error: nil)
    end

    # A reindex resolves its provider through Factory.for_embeddings, which DOES gate
    # on ai_enabled and raises AiDisabledError. Failing the gate here would print a
    # fix the operator cannot run and stay red until someone enables AI.
    it 'WARNS instead of blocking on stranded rows — the printed repair is impossible' do
      sidecar_row(code_symbol, legacy_space)

      expect(result).to have_attributes(
        status: :misaligned, severity: :warning, blocking?: false,
        stranded_count: 1, ai_enabled: false
      )
    end

    it 'stays plain OK when the rows are aligned' do
      sidecar_row(code_symbol, active_space)

      expect(result).to have_attributes(status: :aligned, severity: :ok, blocking?: false)
    end

    it 'BLOCKS the very same finding once AI is enabled (then the reindex works)' do
      sidecar_row(code_symbol, legacy_space)
      organisation.update!(ai_enabled: true)

      expect(result).to have_attributes(status: :misaligned, severity: :error, blocking?: true)
    end
  end

  # The state of an installation with NO embedding credential at all — neither BYOK
  # nor an active system AiCredential. Not the same thing as "AI is off" (see the
  # block above). The check must SAY so instead of dying, so a sweep over all orgs
  # survives and the corpus at risk stays visible.
  describe 'when the read space cannot be resolved' do
    it 'reports :unresolved with the error, and neither aligned nor misaligned' do
      allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
        .and_raise(Lalabase::Llm::Factory::MissingCredentialError,
                   'No active credential configured for provider "openai"')
      sidecar_row(code_symbol, legacy_space)

      expect(result).to have_attributes(
        status: :unresolved, resolved?: false, aligned?: false,
        space: nil, space_label: nil,
        total_count: 1, aligned_count: 0, misaligned_count: 0, stranded_count: 0,
        aligned_groups: [], misaligned_groups: [], stranded_groups: []
      )
      expect(result.error).to eq('MissingCredentialError: No active credential configured for provider "openai"')
    end

    it 'still lists WHICH space the unreadable rows sit in' do
      allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
        .and_raise(Lalabase::Llm::Factory::MissingCredentialError, 'none')
      sidecar_row(code_symbol, legacy_space)

      expect(result.groups.map(&:space_label)).to eq(['openai/text-embedding-ada-002/1536'])
    end

    it 'also survives a plain Provider::Error (unknown/misconfigured provider)' do
      allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
        .and_raise(Lalabase::Llm::Provider::Error, 'Unknown LLM provider: "cohere"')

      expect(result).to have_attributes(status: :unresolved)
      expect(result.error).to eq('Error: Unknown LLM provider: "cohere"')
    end

    # THE silent failure this whole object was built against: with AI enabled and no
    # space, Embeddings::NearestNeighbors#initialize raises on EVERY query and
    # PromptBuildingService rescues StandardError — the chat keeps answering, without
    # context, with nothing but a log warning. Passing that as a harmless warning
    # would let the gate wave through exactly what it exists to catch.
    it 'BLOCKS when AI is ENABLED (retrieval raises on every query, silently)' do
      allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
        .and_raise(Lalabase::Llm::Factory::MissingCredentialError, 'none')
      sidecar_row(code_symbol, legacy_space)

      expect(result).to have_attributes(status: :unresolved, severity: :error, blocking?: true)
    end

    it 'BLOCKS an AI-enabled org even without any sidecar rows — the READ PATH is broken, not the corpus' do
      allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
        .and_raise(Lalabase::Llm::Factory::MissingCredentialError, 'none')

      expect(result).to have_attributes(status: :unresolved, total_count: 0, severity: :error)
    end

    context 'when AI is switched off as well' do
      let(:organisation) { create(:organisation, :ai_disabled) }

      before do
        allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
          .and_raise(Lalabase::Llm::Factory::MissingCredentialError, 'none')
      end

      it 'only warns about rows resting in a space nobody reads' do
        sidecar_row(code_symbol, legacy_space)

        expect(result).to have_attributes(severity: :warning, blocking?: false, soft_error?: true)
      end

      it 'is plain OK with no rows at all — nothing is at risk' do
        expect(result).to have_attributes(severity: :ok, blocking?: false)
      end

      # A provider that cannot embed at all (an org on embedding_provider 'anthropic')
      # is a CONFIGURATION fault. Letting the AI switch downgrade it to a warning
      # would file a broken setup under "AI is simply off" — it never repairs itself.
      it 'BLOCKS a provider that cannot embed, whatever the AI switch says' do
        allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
          .and_raise(Lalabase::Llm::Provider::NotSupportedError, 'Embeddings not supported by anthropic')

        expect(result).to have_attributes(status: :unresolved, soft_error?: false,
                                          severity: :error, blocking?: true)
      end
    end

    # The realistic sweep killer is NOT a Provider::Error: reading
    # credential.access_token can raise a decryption error (an
    # ai_credentials:reencrypt_access_tokens run is still pending in this project).
    # Rescuing only the expected family would break the very promise this reporting
    # was written for — "must not die on org 3 of 200" — and it would do so at the
    # worst moment. Reported and RED: an unknown failure is not proof of harmlessness.
    it 'reports an UNEXPECTED error instead of dying, fully qualified, and blocks' do
      allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
        .and_raise(ActiveRecord::Encryption::Errors::Decryption, 'token undecryptable')

      expect(result).to have_attributes(status: :unresolved, soft_error?: false, severity: :error)
      expect(result.error).to eq('ActiveRecord::Encryption::Errors::Decryption: token undecryptable')
    end
  end

  # No stub here on purpose: this pins that the triple we compare against is the one
  # the real resolution produces (and thus the one the write paths stamp) — a stub
  # would let the two drift apart without a single spec turning red.
  describe 'resolution through the real Factory (unstubbed)' do
    it 'resolves the system-credential default space and matches rows stamped with it' do
      create(:ai_credential, :active, provider: 'openai')
      sidecar_row(code_symbol, active_space)

      expect(result).to have_attributes(space: active_space, status: :aligned)
    end
  end

  # Review finding F1 (2026-08-01). During a staged switch, new content is embedded
  # into the CONFIGURED space (EmbeddingProcessingService uses space: :configured) and
  # therefore has no readable row in the still-ACTIVE one. Counted as stranded, every
  # such record turned the gate red for the whole build window — while the printed fix
  # (`embeddings:reindex`) builds the very space the row already sits in and reports
  # "reindexed 0". That is the silent-failure shape this gate exists to catch,
  # produced BY the gate.
  #
  # The pair below is what gives this teeth: the same unreadable row is a NON-finding
  # when it waits in the target space, and a REAL finding when it does not.
  describe 'during a staged switch (configuration ≠ serving)' do
    let(:target_space) do
      { embedding_provider: 'openai', embedding_model: 'text-embedding-3-large', embedding_dims: 1536 }
    end

    # The Factory answers DIFFERENTLY per space: :active keeps serving the old space,
    # :configured already names the switch target.
    before do
      allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
        .with(anything, space: :active).and_return(active_space)
      allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
        .with(anything, space: :configured).and_return(target_space)
    end

    it 'files content written during the switch as pending_flip, not stranded' do
      sidecar_row(code_symbol, active_space) # existing corpus, readable
      sidecar_row(fragment, target_space)    # written DURING the build

      # severity :warning, not :ok — see the F-A example further down: the same data
      # occurs after a roll-back, where the content stays unreachable indefinitely.
      expect(result).to have_attributes(pending_flip_count: 1, stranded_count: 0,
                                        status: :aligned, severity: :warning)
    end

    # Negative control: a record readable in NEITHER space is unreachable and no flip
    # will rescue it — the gate must still fire. Without this example the change above
    # could degenerate into "nothing is ever stranded during a switch".
    it 'still strands a record that has no readable row in EITHER space' do
      sidecar_row(fragment, legacy_space)

      expect(result).to have_attributes(pending_flip_count: 0, stranded_count: 1,
                                        status: :misaligned, severity: :error)
    end

    it 'reports the switch so the caller can name the right repair' do
      sidecar_row(fragment, target_space)

      expect(result.switch_in_progress?).to be(true)
      expect(result.configured_space).to eq(target_space)
    end

    # The buckets must partition the misaligned set. Each count is pinned INDIVIDUALLY,
    # not just their sum: a sum-only assertion survives any shift BETWEEN buckets, which
    # is exactly the class of bug found in this file twice (review R-C, 2026-08-01 — the
    # earlier version of this example labelled a row `stranded` that was in fact
    # pending_flip, and nothing noticed).
    it 'keeps the buckets disjoint, with each count pinned on its own' do
      symbol = code_symbol
      sidecar_row(symbol, active_space)   # aligned
      sidecar_row(symbol, legacy_space)   # stale — its record HAS a readable row
      pending = fragment
      sidecar_row(pending, target_space)  # pending_flip — waits in the target space
      # stranded needs a THIRD record: one with no readable row anywhere, and none in
      # the target space either.
      sidecar_row(fragment, legacy_space)

      res = result
      expect(res).to have_attributes(aligned_count: 1, stale_count: 1,
                                     pending_flip_count: 1, stranded_count: 1)
      expect(res.stale_count + res.stranded_count + res.pending_flip_count)
        .to eq(res.misaligned_count)
      expect(res.aligned_count + res.misaligned_count).to eq(res.total_count)
    end

    # [F-B, review 2026-08-01] The pending bucket is a ROW property, not just a record
    # property: a leftover from a THIRD space belongs to `stale`, not to "written during
    # the switch". Counting it as pending made two numbers wrong at once — the pending
    # note named a space the row does not live in, and stale_count lost it.
    it 'does not count a third-space leftover as pending' do
      record = fragment
      sidecar_row(record, target_space) # genuinely pending
      sidecar_row(record, legacy_space) # leftover from an older space — stale

      expect(result).to have_attributes(pending_flip_count: 1, stale_count: 1, stranded_count: 0)
      expect(result.pending_flip_groups.map(&:triple)).to eq([target_space])
    end

    # [F-A, review 2026-08-01] The verdict may stay ALIGNED (nothing is unreachable that
    # a flip would not reach), but the severity must NOT be plain :ok: the same data
    # occurs mid-switch AND after a roll-back, and in the second case the content is
    # unreachable indefinitely. A green gate there sent the operator back into the flip
    # that undoes their roll-back.
    it 'warns instead of reporting plain OK while content waits in the configured space' do
      sidecar_row(code_symbol, active_space)
      sidecar_row(fragment, target_space)

      expect(result).to have_attributes(status: :aligned, severity: :warning)
      expect(result.blocking?).to be(false) # a legitimate intermediate state must not fail the gate
    end

    it 'is plain OK once nothing waits in the configured space' do
      sidecar_row(code_symbol, active_space)

      expect(result).to have_attributes(status: :aligned, severity: :ok)
    end
  end

  # [P0, doc/ki_pakete_plan.md §7b.2] The gate's structural blind spot before this: it
  # compares TRIPLES, and embedding_space_for(:active) answers from the snapshot row
  # without ever resolving a credential. A space whose PIN names a disabled, deleted or
  # foreign-provider credential therefore passed as ALIGNED — while every query embedding
  # raised MissingCredentialError and search returned nothing for the whole org. The pin
  # made that failure mode deliberately LOUD at call time; loud at call time is still
  # silent until someone searches, so it has to be visible here too.
  describe 'when the ACTIVE space cannot resolve its credential' do
    let!(:credential) do
      create(:ai_credential, :active, :embedding_only, provider: 'openai',
                                                       default_model: 'text-embedding-3-small',
                                                       access_token: 'sk-system')
    end
    let!(:space) do
      create(:embedding_space, organisation: organisation, ai_credential_id: credential.id,
                               **active_space)
    end

    before { organisation.update!(active_embedding_space_id: space.id, ai_enabled: true) }

    # The whole point: nothing about the triples is wrong, so status stays :aligned and
    # the printed repair must NOT be a reindex — but the gate has to fail.
    it 'stays ALIGNED on the triples and still blocks, naming the credential' do
      sidecar_row(code_symbol, active_space)
      credential.update!(enabled: false)

      outcome = result

      expect(outcome).to have_attributes(status: :aligned, severity: :error, blocking?: true)
      expect(outcome.credential_error).to match(/MissingCredentialError/)
      expect(outcome.credential_error).to match(/#{space.id}/)
    end

    # Same asymmetry as everywhere else in this class: with AI off nothing reads, so a
    # dead credential is a warning, not a gate failure the org could not act on.
    it 'warns instead of blocking while the org has AI switched off' do
      sidecar_row(code_symbol, active_space)
      credential.update!(enabled: false)
      organisation.update!(ai_enabled: false)

      expect(result).to have_attributes(status: :aligned, severity: :warning, blocking?: false)
    end

    # A pin naming another provider resolves to a real, enabled credential — it is only
    # the WRONG one. Without the provider check in Factory#space_credential this would
    # be reported as healthy and then fail as an opaque 401 at the endpoint.
    it 'blocks when the pin names a credential of another provider' do
      sidecar_row(code_symbol, active_space)
      foreign = create(:ai_credential, :embedding_only, provider: 'openai_compatible',
                                                        access_token: 'sk-foreign')
      space.update_column(:ai_credential_id, foreign.id)

      expect(result).to have_attributes(severity: :error, blocking?: true)
    end

    it 'reports no credential fault while the pin resolves' do
      sidecar_row(code_symbol, active_space)

      expect(result).to have_attributes(status: :aligned, severity: :ok, credential_error: nil)
    end

    # A BYOK space serves itself from its own snapshot and resolves no system credential
    # at all — asking one of it would invent a fault out of a healthy row.
    it 'asks nothing of a BYOK space' do
      space.update!(access_token: 'sk-space-own', api_base: 'https://own.example.test/v1')
      credential.update!(enabled: false)

      expect(result.credential_error).to be_nil
    end
  end

  # Without a switch nothing changes: configuration and serving name the same space,
  # so the pending bucket is structurally empty and the verdict is what it always was.
  describe 'without a staged switch' do
    before { stub_default_embedding_space }

    it 'never files anything as pending_flip' do
      sidecar_row(fragment, legacy_space)

      expect(result).to have_attributes(pending_flip_count: 0, stranded_count: 1,
                                        status: :misaligned)
      expect(result.switch_in_progress?).to be(false)
    end
  end

  # Whether the serving space came from the POINTER or from the fallback — the one
  # question #resolved? structurally cannot answer, because embedding_space_for returns
  # the configured triple when no pointer row resolves. An org on the fallback answers
  # queries perfectly well today and is nonetheless incapable of a staged switch
  # (KI-Pakete P4b precondition 3): its next package change moves reads HARD.
  #
  # The two faults stay separate because their repairs are opposite — one is a backfill
  # that was never run, the other is a row that vanished.
  describe 'the vector-space pointer' do
    before { stub_default_embedding_space }

    it 'reports :resolved when the pointer names a real space' do
      space = create(:embedding_space, organisation: organisation)
      organisation.update_column(:active_embedding_space_id, space.id)

      expect(result.pointer_state).to eq(:resolved)
      expect(result.pointer_resolved?).to be(true)
    end

    it 'reports :missing when the organisation has no pointer at all' do
      organisation.update_column(:active_embedding_space_id, nil)

      expect(result.pointer_state).to eq(:missing)
      expect(result.pointer_resolved?).to be(false)
    end

    # A pointer that resolves to no space OF THIS ORG. Note how it has to be built: a
    # made-up id is rejected by the FK, and deleting the row nullifies the column into
    # :missing — so the only way in is a FOREIGN org's space, exactly the "cross-org id"
    # Factory#warn_dangling_pointer names. That is why :dangling is a DATA FAULT with a
    # different repair, not a backfill that was never run.
    it 'reports :dangling when the pointer names another organisation\'s space' do
      # with_tenant, not just `organisation:` — acts_as_tenant stamps the AMBIENT tenant
      # on create, so building it under this org's tenancy would silently produce a
      # space belonging to the org under test and prove nothing.
      foreign_space = ActsAsTenant.with_tenant(foreign_org) do
        create(:embedding_space, organisation: foreign_org)
      end
      organisation.update_column(:active_embedding_space_id, foreign_space.id)

      expect(result.pointer_state).to eq(:dangling)
      expect(result.pointer_resolved?).to be(false)
    end

    # A pointerless org still comes out ALIGNED, which is why this state needs a channel
    # of its own instead of being folded into #status.
    #
    # Honest about its own reach: stub_default_embedding_space stubs
    # Factory.embedding_space_for WITHOUT `.with(...)`, so both lanes get the same value
    # from the STUB here — the real fallback in factory.rb is not what this example
    # exercises, and deleting it would leave this green. The unstubbed proof lives in
    # embeddings_check_alignment_spec, which runs the task through the real Factory. What
    # this example does pin is that pointer_state is independent of the verdict.
    it 'still reads as aligned without a pointer, which is why this is reported apart' do
      organisation.update_column(:active_embedding_space_id, nil)

      expect(result.status).to eq(:aligned)
      expect(result.switch_in_progress?).to be(false)
      expect(result.pointer_resolved?).to be(false)
    end

    # A hand-built Result (specs, and any future caller not going through .call) must
    # not read as faulty.
    it 'treats an undetermined state as ok' do
      expect(described_class::Result.new(organisation: organisation).pointer_resolved?).to be(true)
    end
  end
end
