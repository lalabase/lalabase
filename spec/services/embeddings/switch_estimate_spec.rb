# frozen_string_literal: true

# What: Embeddings::SwitchEstimate — the "ca. N Datensätze, ca. X Credits" the
#   P4b consequence dialog quotes before a package switch (plan E7).
# Type: Service spec, real queries against the four embedded tables.
# Why (philosophy): this number is shown to a customer next to their remaining
#   quota and decides whether they press the button, so the examples pin the two
#   things that make it either honest or misleading: WHICH rows it counts (its
#   own org's, across the tables the reindexer actually processes) and HOW it
#   prices them (rounded UP into whole token blocks — but never the 1-credit
#   floor for a corpus that would book nothing at all).
# Contract: records/characters aggregate the org's rows in
#   OrganisationReindexer::TARGETS; tokens = ceil(characters / 4); credits are the
#   DOCUMENT_INDEXING tariff, and 0 for an empty corpus.

require 'rails_helper'

RSpec.describe Embeddings::SwitchEstimate do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  # The four target tables are tenant-scoped; every row here is written inside its
  # own org's frame so the isolation example below cannot pass by accident.
  def capability(text, org: organisation, on: project)
    ActsAsTenant.with_tenant(org) do
      create(:project_capability, project: on, organisation: org, description: text)
    end
  end

  def vision(text, org: organisation, on: project)
    ActsAsTenant.with_tenant(org) do
      create(:project_layer4_vision, project: on, organisation: org, content: text)
    end
  end

  it 'sums rows and characters across the tables the reindex actually walks' do
    capability('a' * 40)
    vision('b' * 60)

    estimate = described_class.call!(organisation: organisation)

    expect(estimate.records).to eq(2)
    expect(estimate.characters).to eq(100)
  end

  # ONE row in EVERY target table, with four distinguishable lengths.
  #
  # Until this example the suite only ever built capabilities, visions and one
  # signature-less code symbol — no example ever measured a Fragment. Proven rather
  # than assumed: replacing `TARGETS.each` with `TARGETS.first(3).each` dropped
  # Fragment out of the measurement and all nine examples stayed green. The
  # contain_exactly pin next door checks the CONSTANT's contents; it never calls
  # this service, so it cannot see a subset being walked.
  #
  # It matters most for exactly the table that was missing: fragments
  # .plain_text_content is the only one of the four with genuinely large texts, so a
  # measurement that silently drops it understates the estimate by its biggest item
  # — and then the quota warning stays quiet.
  it 'measures every target table, not a subset of them' do
    capability('a' * 1)
    vision('b' * 20)
    ActsAsTenant.with_tenant(organisation) do
      create(:code_symbol, organisation: organisation, signature: 'c' * 300)
      create(:fragment, :for_ticket, organisation: organisation,
                                     plain_text_content: 'd' * 4_000)
    end

    estimate = described_class.call!(organisation: organisation)

    expect(estimate.records).to eq(4)
    # Distinct magnitudes: any table dropped changes the sum, and the sum names
    # which one.
    expect(estimate.characters).to eq(4_321)
  end

  # A shared estimate across orgs would quote a customer for a corpus they neither
  # own nor pay for — and the four models are exactly where an unscoped
  # `klass.all` would leak.
  it 'ignores another organisation\'s corpus' do
    capability('a' * 40)
    other_org = create(:organisation)
    other_project = ActsAsTenant.with_tenant(other_org) { create(:project, organisation: other_org) }
    capability('z' * 4_000, org: other_org, on: other_project)

    estimate = described_class.call!(organisation: organisation)

    expect(estimate.records).to eq(1)
    expect(estimate.characters).to eq(40)
  end

  # DOCUMENT_INDEXING bills one credit per STARTED 1.000-token block, and tokens
  # are characters/4 rounded up. Both roundings go the same way, so the two sides
  # of the block boundary are where a floor/ceil slip becomes a price that is too
  # low — the direction that matters, because the customer decides on this number.
  describe 'the token and credit arithmetic' do
    it 'prices a corpus that lands exactly on the block boundary at one credit' do
      capability('a' * 4_000)

      estimate = described_class.call!(organisation: organisation)

      expect(estimate.tokens).to eq(1_000)
      expect(estimate.credits).to eq(1)
    end

    it 'prices one character more as a second, started block' do
      capability('a' * 4_001)

      estimate = described_class.call!(organisation: organisation)

      # 4001 / 4 = 1000.25 → 1001 tokens, i.e. into the second block.
      expect(estimate.tokens).to eq(1_001)
      expect(estimate.credits).to eq(2)
    end
  end

  # The one place the estimate must NOT follow ActionRegistry.credits_for: that
  # method floors every priced call at one started block, while
  # OrganisationReindexer#record_run_usage writes no usage row at all for a
  # zero-token run. Quoting 1 credit here would name a price no run ever charges —
  # and it would do so on the screen of exactly the org with nothing to migrate.
  it 'quotes nothing for an empty corpus' do
    estimate = described_class.call!(organisation: organisation)

    expect(estimate.records).to eq(0)
    expect(estimate.tokens).to eq(0)
    expect(estimate.credits).to eq(0)
  end

  # A record with no source text is still a record the reindexer walks — it just
  # costs nothing. Counting it as a row keeps "ca. N Datensätze" honest.
  it 'counts a row without source text as a record with no characters' do
    # code_symbols.signature is one of the two nullable source columns — the case
    # exists in the data, so SUM answering NULL has to survive the trip.
    ActsAsTenant.with_tenant(organisation) do
      create(:code_symbol, organisation: organisation, signature: nil)
    end

    estimate = described_class.call!(organisation: organisation)

    expect(estimate.records).to eq(1)
    expect(estimate.characters).to eq(0)
  end

  # The reindexer decides which tables a switch re-embeds; a second list here
  # would price a corpus the run does not process (or miss one it does).
  it 'reads its table list from the reindexer rather than keeping its own' do
    expect(Embeddings::OrganisationReindexer::TARGETS.map { |target| target[:model] })
      .to contain_exactly('CodeSymbol', 'ProjectCapability', 'ProjectLayer4Vision', 'Fragment')
  end

  # Every example above calls .call! — the UNCACHED form — on purpose. The dialog
  # uses the cached .call, and that needs its own examples with a REAL store: the
  # test environment runs :null_store (config/environments/test.rb:28), so a
  # Rails.cache.fetch here does nothing whatsoever, and an example asserting on it
  # would pass just as happily against a cache that was never wired up. Same lesson
  # as the limits_concurrency defect: assert the mechanism, not the declaration.
  describe '.call (the cached form the dialog uses)' do
    around do |example|
      previous = Rails.cache
      # Scoped to the example: the null store cannot show caching at all, and a
      # suite-wide memory store would leak estimates between examples.
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      example.run
    ensure
      Rails.cache = previous
    end

    # Four full-corpus aggregates, each with SUM(LENGTH(text)) — which detoasts and
    # decompresses every row it touches — on a GET the customer can hold F5 on,
    # against the shared production database (#437 review, finding 3).
    it 'computes once and serves the repeat from cache' do
      capability('x' * 4_000)

      first = described_class.call(organisation: organisation)
      # A recomputation would SEE this and report a larger corpus.
      capability('y' * 4_000)
      second = described_class.call(organisation: organisation)

      expect(first.characters).to eq(4_000)
      expect(second.characters).to eq(4_000)
      # ...and the uncached form proves the corpus really did grow, so the example
      # cannot pass because both calls simply measured nothing.
      expect(described_class.call!(organisation: organisation).characters).to eq(8_000)
    end

    it 'keeps one organisation\'s estimate out of another\'s' do
      other = create(:organisation)
      capability('x' * 4_000)

      expect(described_class.call(organisation: organisation).characters).to eq(4_000)
      expect(described_class.call(organisation: other).characters).to eq(0)
    end
  end
end
