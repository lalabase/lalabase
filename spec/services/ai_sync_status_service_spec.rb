# frozen_string_literal: true

# What: AiSyncStatusService — the read model of the Indexierung page.
# Type: Service spec; the type list is DERIVED from Embeddings::ContentTypes throughout.
# Why (philosophy): Until 04.09.2026 this service kept a private list of four types and
#   counted fragments of a type that does not exist, so the page hid five of nine backlogs
#   and showed 0/0 fragments for every document. The examples under "the gaps the
#   registry closed" were red against that version. The rest pins the shape the view
#   reads, the split between pending and failed (the same split the summary at the top of
#   the page makes), and tenant isolation for EVERY registered type — the raw grouped
#   query binds the organisation by hand, and a spec with one organisation cannot see a
#   missing filter.
# Contract: { overview:, projects: [{ project:, by_type: { key => 7 figures }, totals: }],
#   fragments: }; overview = sum of the project rows; by_type has a row per registry key,
#   in registry order.

require 'rails_helper'

RSpec.describe AiSyncStatusService do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }

  after { ActsAsTenant.current_tenant = nil }

  def result
    described_class.call(organisation: organisation)
  end

  def row_for(key)
    result[:projects].first[:by_type].fetch(key)
  end

  describe '.call' do
    it 'returns overview, projects and fragments' do
      expect(result.keys).to contain_exactly(:overview, :projects, :fragments)
    end

    context 'with an empty organisation' do
      it 'reports zero everywhere' do
        overview = result[:overview]

        expect(overview.values_at(:total_content, :with_embeddings, :pending_embeddings, :embedding_errors,
                                  :total_fragments, :fragments_with_embeddings)).to all(eq(0))
        expect(result[:projects]).to be_empty
        expect(result[:fragments][:by_type]).to be_empty
        expect(result[:fragments][:recent_fragments]).to be_empty
      end
    end
  end

  describe 'the gaps the registry closed (red before 04.09.2026)' do
    it 'counts a pending, opted-in meeting in the overview' do
      create(:meeting, project: project, organisation: organisation, creator: user, create_embeddings: true)

      expect(result[:overview][:pending_embeddings]).to eq(1)
      expect(row_for(:meetings)[:pending_embeddings]).to eq(1)
    end

    it 'counts a present documentation page in the overview' do
      create(:documentation_page, documentation_set: create(:documentation_set, project: project))

      expect(result[:overview][:pending_embeddings]).to eq(1)
      expect(row_for(:documentation_pages)[:pending_embeddings]).to eq(1)
    end

    # The old code joined `fragmentable_type = 'Document'`. No such fragment has ever
    # existed — only DocumentVersion has fragments — so this cell read 0/0 for ever.
    it 'counts a DocumentVersion fragment in the documents row of its project' do
      version = create_pending_record(:document_versions, organisation: organisation, project: project, user: user)
      create(:fragment, fragmentable: version, organisation: organisation)

      expect(row_for(:document_versions)[:fragments_count]).to eq(1)
    end

    it 'has a row for every registered type, in registry order' do
      project

      expect(result[:projects].first[:by_type].keys).to eq(Embeddings::ContentTypes.keys)
    end
  end

  describe 'overview' do
    let!(:note_enabled) { create(:note, project: project, organisation: organisation, creator: user, create_embeddings: true) }
    let!(:note_disabled) { create(:note, project: project, organisation: organisation, creator: user, create_embeddings: false) }
    let!(:ticket) { create(:ticket, project: project, organisation: organisation, creator: user) }
    let!(:ticket2) { create(:ticket, project: project, organisation: organisation, creator: user) }
    let!(:post) { create(:post, ticket: ticket2, organisation: organisation, user: user, create_embeddings: true) }

    it 'counts every record as content and only opted-in ones as enabled' do
      overview = result[:overview]

      expect(overview[:total_content]).to eq(5)
      # 1 note + 2 tickets (always enabled) + 1 post
      expect(overview[:with_embeddings]).to eq(4)
      expect(overview[:pending_embeddings]).to eq(4)
    end

    # Both halves, because the backlog only says where a record LEFT. `processed` is the
    # only figure the progress ring and the mini bars read (show.html.erb), it has one
    # production caller, and asserting it as 0 everywhere else leaves two mutations alive:
    # `ContentTypes.processed` flipped to `= FALSE` (NULL flags make that NULL, never
    # TRUE) and `0 AS processed` in the grouped query. Both would put every ring on the
    # page at 0 % for ever, with a green suite.
    it 'takes processed records out of the backlog and reports them as processed' do
      note_enabled.update!(embeddings_creation_flag: true)
      ticket.update!(embeddings_creation_flag: true)

      expect(result[:overview][:pending_embeddings]).to eq(2)
      expect(result[:projects].first[:totals][:embeddings_processed]).to eq(2)
      expect(row_for(:notes)[:embeddings_processed]).to eq(1)
    end

    # The split the summary at the top of the same page makes (Embeddings::IndexHealth):
    # a failed record is failed, not outstanding. Before, the page counted it in both
    # tiles and contradicted the sentence above it.
    it 'reports a failed record as an error and NOT as pending' do
      note_enabled.update!(embedding_creation_error: 'Some error')
      post.update!(embedding_creation_error: 'Another error')
      overview = result[:overview]

      expect(overview[:embedding_errors]).to eq(2)
      expect(overview[:pending_embeddings]).to eq(2)
    end

    it 'ignores an error on a record that was never meant to be embedded' do
      note_disabled.update!(embedding_creation_error: 'stale')

      expect(result[:overview][:embedding_errors]).to eq(0)
    end

    # No second count: the tiles are the sum of the rows, so they cannot disagree with
    # the table under them.
    it 'is the sum of the project rows' do
      totals = result[:projects].sum { |row| row[:totals][:pending_embeddings] }

      expect(result[:overview][:pending_embeddings]).to eq(totals)
    end
  end

  describe 'per project' do
    let!(:note_enabled) { create(:note, project: project, organisation: organisation, creator: user, create_embeddings: true) }
    let!(:note_disabled) { create(:note, project: project, organisation: organisation, creator: user, create_embeddings: false) }
    let!(:ticket) { create(:ticket, project: project, organisation: organisation, creator: user) }
    let!(:ticket2) { create(:ticket, project: project, organisation: organisation, creator: user) }
    let!(:post) { create(:post, ticket: ticket2, organisation: organisation, user: user, create_embeddings: true) }

    it 'names the project' do
      expect(result[:projects].first[:project]).to eq(project)
    end

    it 'counts notes' do
      expect(row_for(:notes)).to include(total: 2, embeddings_enabled: 1, embeddings_processed: 0,
                                         pending_embeddings: 1, with_errors: 0)
    end

    it 'counts tickets, which are always enabled' do
      expect(row_for(:tickets)).to include(total: 2, embeddings_enabled: 2, pending_embeddings: 2)
    end

    it 'counts posts through their ticket' do
      expect(row_for(:posts)).to include(total: 1, embeddings_enabled: 1, pending_embeddings: 1)
    end

    # ⚠️ `eq(EMPTY_STATS)` on its own is a tautology: the empty row IS that constant
    # (the fetch default in #stats_by_project). So the constant is held against a
    # literal, and a row built with data is held against STAT_KEYS — that pair is what
    # notices a key leaving the list. Without it, dropping the two fragment keys from
    # STAT_KEYS shrinks both sides of every assertion together and the page renders
    # "/" instead of "0/0" in every cell of a type a project has none of.
    it 'reports an empty row for a type the project has none of' do
      expect(row_for(:document_versions)).to eq(described_class::EMPTY_STATS)
      expect(described_class::EMPTY_STATS).to eq(total: 0, embeddings_enabled: 0, embeddings_processed: 0,
                                                 pending_embeddings: 0, with_errors: 0,
                                                 fragments_count: 0, fragments_with_embeddings: 0)
      expect(row_for(:notes).keys).to match_array(described_class::STAT_KEYS)
    end

    it 'totals the rows' do
      expect(result[:projects].first[:totals]).to include(total: 5, embeddings_enabled: 4,
                                                          embeddings_processed: 0, pending_embeddings: 4, with_errors: 0)
    end
  end

  describe 'fragments per project' do
    it 'counts a type\'s fragments and, separately, the embedded ones' do
      note = create(:note, project: project, organisation: organisation, creator: user)
      create(:fragment, fragmentable: note, organisation: organisation)
      embedded = create(:fragment, fragmentable: note, organisation: organisation)
      seed_sidecar_embedding(embedded, vector: Array.new(1536, 0.1))

      expect(row_for(:notes)).to include(fragments_count: 2, fragments_with_embeddings: 1)
    end

    # The page asks whether CURRENT content is embedded; a superseded version's fragments
    # are history here. The org-wide "by type" figures at the foot still count them.
    it 'counts only the current version\'s fragments for a document' do
      document = create(:document, project: project, organisation: organisation)
      old_version = create(:document_version, document: document, organisation: organisation)
      current = create(:document_version, document: document, organisation: organisation)
      document.update!(current_version: current)
      create(:fragment, fragmentable: old_version, organisation: organisation)
      create(:fragment, fragmentable: current, organisation: organisation)

      expect(row_for(:document_versions)[:fragments_count]).to eq(1)
      expect(result[:fragments][:by_type]['DocumentVersion']).to eq(2)
    end
  end

  describe 'several projects' do
    let(:project2) { create(:project, organisation: organisation) }

    before do
      create(:note, project: project, organisation: organisation, creator: user, create_embeddings: true)
      create(:note, project: project2, organisation: organisation, creator: user, create_embeddings: true)
      create(:ticket, project: project, organisation: organisation, creator: user)
      create(:ticket, project: project2, organisation: organisation, creator: user)
    end

    it 'reports each project on its own and the organisation as their sum' do
      rows = result[:projects]

      expect(rows.length).to eq(2)
      expect(rows.map { |row| row[:totals][:total] }).to eq([2, 2])
      expect(result[:overview][:total_content]).to eq(4)
    end
  end

  # ⚠️ The raw grouped query binds organisation_id by hand — acts_as_tenant is not in
  # play there, exactly as in Embeddings::IndexHealth. Every registered type is planted
  # in a FOREIGN organisation, because one unrepresented type is one type whose filter
  # nobody is holding.
  describe 'tenant isolation, for every registered type' do
    let(:other) { create(:organisation) }
    let(:other_project) { ActsAsTenant.with_tenant(other) { create(:project, organisation: other) } }

    def plant_foreign_content
      Embeddings::ContentTypes.entries.map do |entry|
        create_pending_record(entry.key, organisation: other, project: other_project, user: user)
      end
    end

    it 'never counts another organisation\'s content' do
      plant_foreign_content
      project

      expect(result[:overview].values_at(:total_content, :with_embeddings, :pending_embeddings,
                                         :embedding_errors)).to all(eq(0))
      expect(result[:projects].first[:totals]).to eq(described_class::EMPTY_STATS)
    end

    # The other half of the same argument, and the half the example above stopped short
    # of: the fragment figures reach the page through Fragment rather than through the
    # bound raw SQL, so `Fragment.unscoped` (or a without_tenant wrapper) anywhere in
    # #fragment_counts_by_project, #overview or #fragment_statistics would leak. And the
    # leak would not stay a number: show.html.erb renders every recent fragment's type
    # and timestamp, so a foreign tenant's fragment metadata would appear on this
    # organisation's admin page.
    it 'never counts, or lists, another organisation\'s fragments' do
      foreign = plant_foreign_content
      ActsAsTenant.with_tenant(other) do
        foreign.each { |record| seed_sidecar_embedding(create(:fragment, fragmentable: record, organisation: other), vector: Array.new(1536, 0.1)) }
      end
      project

      expect(result[:overview].values_at(:total_fragments, :fragments_with_embeddings)).to all(eq(0))
      expect(result[:projects].first[:totals][:fragments_count]).to eq(0)
      expect(result[:fragments][:by_type]).to be_empty
      expect(result[:fragments][:recent_fragments]).to be_empty
    end
  end

  describe 'fragment statistics' do
    let!(:note) { create(:note, project: project, organisation: organisation, creator: user) }
    let!(:ticket) { create(:ticket, project: project, organisation: organisation, creator: user) }
    let!(:fragment_note) { create(:fragment, fragmentable: note, organisation: organisation) }
    let!(:fragment_ticket_with_embedding) do
      fragment = create(:fragment, fragmentable: ticket, organisation: organisation)
      # "Embedded" is answered by the SIDECAR (Fragment#with_sidecar_embedding), so the
      # fragment only counts once it has an indexed sidecar row.
      seed_sidecar_embedding(fragment, vector: Array.new(1536, 0.1))
      fragment
    end

    it 'groups fragments by type' do
      fragments = result[:fragments]

      expect(fragments[:by_type]).to include('Note' => 1, 'Ticket' => 1)
      expect(fragments[:with_embeddings_by_type]['Note'] || 0).to eq(0)
      expect(fragments[:with_embeddings_by_type]['Ticket']).to eq(1)
    end

    it 'lists recent fragments' do
      expect(result[:fragments][:recent_fragments]).to contain_exactly(fragment_note, fragment_ticket_with_embedding)
    end
  end

  # Embedding v2 PR 5 §3.4.2: the page used to count `where.not(embedding: nil)` on the
  # inline column. With the PR-5 write guard that column stays NULL for a non-1536 org,
  # so such an org would have been reported as permanently unembedded although its
  # sidecar is full — a monitoring lie, not a functional break, but one nobody could
  # explain from the page.
  describe 'non-1536 organisations (sidecar EXISTS instead of the inline column)' do
    let!(:note) { create(:note, project: project, organisation: organisation, creator: user) }

    def seed_mistral_sidecar(fragment)
      create(:content_embedding, embeddable: fragment, organisation: organisation,
                                 embedding: Array.new(1024, 0.1), embedding_dims: 1024,
                                 embedding_provider: 'openai_compatible', embedding_model: 'mistral-embed',
                                 indexed: true)
    end

    it 'counts a fragment whose vector only exists in a 1024 sidecar row' do
      seed_mistral_sidecar(create(:fragment, fragmentable: note, organisation: organisation))

      expect(result[:overview][:fragments_with_embeddings]).to eq(1)
    end

    # Counterpart, so the scope cannot degenerate into "has any sidecar row": a row
    # that is not indexed does not count (the state the orphan GC / a pending reindex
    # leaves behind).
    it 'does NOT count a fragment whose sidecar row is not indexed' do
      fragment = create(:fragment, fragmentable: note, organisation: organisation)
      create(:content_embedding, embeddable: fragment, organisation: organisation, indexed: false)

      expect(result[:overview][:fragments_with_embeddings]).to eq(0)
    end

    # Review finding S1: the counters moved to the sidecar, the "recent fragments" list
    # in the view did not — it kept asking fragment.embedding. For a 1024 org the page
    # then contradicted ITSELF (counter "1 embedded", list right below "not embedded").
    # The view now reads this precomputed id set, so both halves share one source.
    it 'marks a 1024-sidecar fragment as embedded in the recent-fragments list' do
      fragment = create(:fragment, fragmentable: note, organisation: organisation)
      seed_mistral_sidecar(fragment)
      stats = result[:fragments]

      expect(stats[:recent_fragments].map(&:id)).to include(fragment.id)
      expect(stats[:recent_fragment_ids_with_embedding]).to include(fragment.id)
    end

    it 'leaves a fragment without any sidecar row out of that set' do
      fragment = create(:fragment, fragmentable: note, organisation: organisation)
      stats = result[:fragments]

      expect(stats[:recent_fragments].map(&:id)).to include(fragment.id)
      expect(stats[:recent_fragment_ids_with_embedding]).not_to include(fragment.id)
    end
  end
end
