# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::Tools::SearchKnowledge — the MCP tool that finds notes/documents by
#       title and hands back a ready-to-paste lalabase:// link per hit.
# Type: Service spec.
# Why:  Two things must hold: (1) results are policy-scoped, so a user without read
#       access NEVER sees a foreign title (the MCP side-door the chat double-gate closes),
#       and (2) the emitted link string is exactly what the resolver parses back (the
#       author round-trip). Both target types must work.
RSpec.describe Lalabase::Tools::SearchKnowledge do
  include ActiveSupport::Testing::TimeHelpers # travel_to, for deterministic updated_at ordering

  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:role)         { create(:role, organisation: organisation, is_default: true) }

  let(:actor) do
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    user
  end

  let(:context) { Lalabase::Tools::Context.new(actor: actor, organisation: organisation, project: project) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def grant(**areas)
    create(:project_permission, { user: actor, project: project }.merge(areas))
  end

  def create_document(title:)
    doc = create(:document, project: project, organisation: organisation)
    version = create(:document_version, document: doc, organisation: organisation, title: title)
    doc.update!(current_version: version)
    doc
  end

  def run(args)
    JSON.parse(described_class.execute(args: args, context: context).content)
  end

  describe 'schema metadata' do
    it 'declares the public tool name and requires q' do
      expect(described_class.tool_name).to eq('search_knowledge')
      expect(described_class.input_schema[:required]).to eq(['q'])
    end

    it 'is a read tool (usable with a read-only PAT)' do
      expect(described_class.mutating?).to be false
      expect(described_class.authorization_mode).to eq(:project)
    end
  end

  # The tool lives on the MCP surface ONLY — adding it to the chat registry would change
  # chat behaviour, which Slice 4 deliberately does not. The chat side is also pinned by
  # registry_spec's contain_exactly; this states both halves of the decision co-located
  # with the tool, so a future refactor sees the intent right here.
  describe 'registration surface (MCP-only, not chat)' do
    it 'is registered on the MCP dispatcher' do
      expect(Mcp::Dispatcher::TOOLS).to include(described_class)
    end

    it 'is in NO chat tool set (chat behaviour stays unchanged)' do
      # Registry::ALL was the per-project chat's set under a backward-compatible name
      # and went with it (projekt_chat_abbau). Asked over CHAT_SETS now, which is
      # stricter: it covers every surface that reaches the LLM tool loop.
      Lalabase::Tools::Registry::CHAT_SETS.each do |set|
        expect(Lalabase::Tools::Registry.for(set)).not_to include(described_class), "#{set} must not offer it"
      end
    end
  end

  describe 'search matching semantics' do
    before { grant(notes_access: 'read_only') }

    it 'escapes LIKE wildcards in q so a percent matches literally, not as a wildcard' do
      create(:note, project: project, organisation: organisation, title: 'Cost a%b breakdown')
      create(:note, project: project, organisation: organisation, title: 'axxb should not match')

      # Escaped, "a%b" matches only the literal "a%b"; unescaped it would be `a`-anything-`b`
      # and also catch "axxb". Removing sanitize_sql_like turns this red.
      titles = run(q: 'a%b')['data'].map { |hit| hit['title'] }

      expect(titles).to include('Cost a%b breakdown')
      expect(titles).not_to include('axxb should not match')
    end
  end

  describe 'input guards' do
    it 'errors when the project context is missing' do
      blank = Lalabase::Tools::Context.new(actor: actor, organisation: organisation, project: nil)
      result = described_class.execute(args: { q: 'x' }, context: blank)
      expect(result.error).to eq('project context missing')
    end

    it 'errors when q is blank' do
      expect(described_class.execute(args: { q: '  ' }, context: context).error).to eq('q is required')
    end

    it 'rejects a hallucinated type argument' do
      grant(notes_access: 'read_only')
      result = described_class.execute(args: { q: 'x', type: 'ticket' }, context: context)
      expect(result.error).to eq('invalid type (expected "note" or "document")')
    end
  end

  describe 'finding knowledge (both target types)' do
    before { grant(notes_access: 'read_only', documents_access: 'read_only') }

    it 'finds a note by title and returns its link + fields' do
      note = create(:note, project: project, organisation: organisation, title: 'Alpha Runbook')

      payload = run(q: 'Alpha')

      hit = payload['data'].sole
      expect(hit).to include('type' => 'note', 'id' => note.id, 'title' => 'Alpha Runbook',
                             'link' => "lalabase://note/#{note.id}")
      expect(hit['updated_at']).to be_present
      expect(payload['meta']).to include('page' => 1, 'total' => 1)
    end

    it 'finds a document by title too (positive iteration over BOTH types)' do
      document = create_document(title: 'Beta Design')

      payload = run(q: 'Beta')

      hit = payload['data'].sole
      expect(hit).to include('type' => 'document', 'id' => document.id, 'title' => 'Beta Design',
                             'link' => "lalabase://document/#{document.id}")
    end

    it 'filters by type = note' do
      create(:note, project: project, organisation: organisation, title: 'Shared Word')
      create_document(title: 'Shared Word')

      payload = run(q: 'Shared', type: 'note')

      expect(payload['data'].map { |h| h['type'] }).to eq(['note'])
    end

    it 'filters by type = document' do
      create(:note, project: project, organisation: organisation, title: 'Shared Word')
      create_document(title: 'Shared Word')

      payload = run(q: 'Shared', type: 'document')

      expect(payload['data'].map { |h| h['type'] }).to eq(['document'])
    end

    it 'returns an emitted link the resolver parses straight back (build/parse contract)' do
      note = create(:note, project: project, organisation: organisation, title: 'Round Trip')

      link = run(q: 'Round Trip')['data'].sole['link']

      expect(Documentation::KnowledgeLink.parse(link)).to eq(type: 'note', id: note.id)
    end

    it 'serializes multiple documents (title preloaded — no per-row current_version N+1)' do
      # Setup is paused so only the tool call is scanned (spec/support/prosopite.rb scans
      # every example). Removing preload_titles turns document.title into a per-row
      # current_version load and this goes red — the mutation guard for that preload.
      Prosopite.pause do
        3.times { |i| create_document(title: "Design Doc #{i}") }
      end

      payload = run(q: 'Design Doc')

      expect(payload['data'].size).to eq(3)
      expect(payload['data'].map { |hit| hit['title'] }).to all(be_present)
    end

    it 'does not leak a note from another project of the same org' do
      other_project = create(:project, organisation: organisation)
      create(:note, project: other_project, organisation: organisation, title: 'Foreign Note')

      expect(run(q: 'Foreign')['data']).to eq([])
    end

    it 'orders notes and documents together strictly newest-first (merge across types)' do
      # Make the DOCUMENT the newer of the two (document arm orders on documents.updated_at);
      # a per-type sort would misorder the cross-type merge, so this pins recency ordering.
      note = travel_to(2.days.ago) { create(:note, project: project, organisation: organisation, title: 'Merge Item note') }
      document = travel_to(1.day.ago) { create_document(title: 'Merge Item doc') }

      ids = run(q: 'Merge Item')['data'].map { |hit| hit['id'] }

      expect(ids).to eq([document.id, note.id])
    end
  end

  describe 'pagination across the merged arms' do
    before { grant(notes_access: 'read_only') }

    it 'orders newest-first and pages the merged result without overlap' do
      older = travel_to(2.days.ago) { create(:note, project: project, organisation: organisation, title: 'Paged Note A') }
      newer = travel_to(1.day.ago) { create(:note, project: project, organisation: organisation, title: 'Paged Note B') }

      page1 = run(q: 'Paged Note', per_page: 1, page: 1)
      page2 = run(q: 'Paged Note', per_page: 1, page: 2)

      expect(page1['data'].map { |hit| hit['id'] }).to eq([newer.id]) # newest first
      expect(page2['data'].map { |hit| hit['id'] }).to eq([older.id])
      expect(page1.dig('meta', 'total')).to eq(2)
      expect(page2.dig('meta', 'total')).to eq(2)
    end

    it 'returns an empty page — with the correct total — past the last result' do
      create(:note, project: project, organisation: organisation, title: 'Only One Note')

      payload = run(q: 'Only One Note', page: 5, per_page: 10)

      expect(payload['data']).to eq([])
      expect(payload.dig('meta', 'total')).to eq(1)
    end

    it 'covers every matching row exactly once across pages, even when updated_at ties' do
      # Completeness guard: paging must not drop or repeat a row. Ties on updated_at are
      # the stress case. NOTE this cannot by itself PROVE the SQL id-tiebreak is needed —
      # Postgres returns tied rows in a stable order WITHIN a session, so the ordering is
      # incidentally consistent even without it; the tiebreak defends the case where that
      # heap order is NOT stable (post-VACUUM, different PG version, parallel scan).
      # Prosopite is paused: one tool call per page is three INDEPENDENT requests (identical
      # query shape by design), not an in-request N+1.
      Prosopite.pause do
        notes = travel_to(1.day.ago) do
          Array.new(3) { |i| create(:note, project: project, organisation: organisation, title: "Tie Note #{i}") }
        end

        seen = (1..3).flat_map { |page| run(q: 'Tie Note', per_page: 1, page: page)['data'].map { |hit| hit['id'] } }

        expect(seen).to match_array(notes.map(&:id)) # every row exactly once across the pages
      end
    end
  end

  describe 'policy scoping (the security seam)' do
    it 'returns NO note hits — not even the title — for a user without notes read access' do
      create(:note, project: project, organisation: organisation, title: 'Confidential Note')
      # actor has a membership but no notes permission → policy_scope yields nothing.
      payload = run(q: 'Confidential')

      expect(payload['data']).to eq([])
      expect(payload.dig('meta', 'total')).to eq(0)
      expect(described_class.execute(args: { q: 'Confidential' }, context: context).content)
        .not_to include('Confidential Note')
    end

    it 'returns NO document hits for a user without documents read access' do
      grant(notes_access: 'read_only') # notes allowed, documents NOT
      create_document(title: 'Secret Doc')

      expect(run(q: 'Secret')['data']).to eq([])
    end
  end

  describe 'pagination' do
    before { grant(notes_access: 'read_only') }

    it 'caps per_page at MAX_PER_PAGE' do
      payload = run(q: 'x', per_page: described_class::MAX_PER_PAGE + 50)
      expect(payload['meta']['per_page']).to eq(described_class::MAX_PER_PAGE)
    end

    it 'defaults per_page and page for a bare query' do
      payload = run(q: 'x')
      expect(payload['meta']).to include('page' => 1, 'per_page' => described_class::DEFAULT_PER_PAGE)
    end
  end
  # G2 (Review, Runde 2): the rights gate of an ANSWER runs on its citations' area. This
  # tool sits in :mcp only today (no LLM loop), so citing changes
  # nothing now — it means switching the set on later stays a registry line instead of a
  # repeat of the ungated-content finding on the knowledge areas.
  describe 'citations (the gate for other readers of a shared chat)' do
    before { grant(notes_access: 'read_only', documents_access: 'read_only') }

    it 'cites a note with the notes area' do
      note = create(:note, project: project, organisation: organisation, title: 'Architektur')

      cites = described_class.execute(args: { q: 'Architektur' }, context: context).citations

      expect(cites.map { |c| c[:id] }).to eq([note.id])
      expect(Lalabase::Citations.areas_of(cites.map(&:stringify_keys))).to eq([:notes])
    end

    it 'cites a document with the documents area' do
      doc = create_document(title: 'Betriebshandbuch')

      cites = described_class.execute(args: { q: 'Betriebshandbuch' }, context: context).citations

      expect(cites.map { |c| c[:id] }).to eq([doc.id])
      expect(Lalabase::Citations.areas_of(cites.map(&:stringify_keys))).to eq([:documents])
    end

    it 'cites nothing when the policy scope returned nothing' do
      create(:note, project: project, organisation: organisation, title: 'Architektur')
      bare = Lalabase::Tools::Context.new(actor: create(:user), organisation: organisation, project: project)

      expect(described_class.execute(args: { q: 'Architektur' }, context: bare).citations).to be_empty
    end

    it 'caps the citations without capping the returned rows' do
      (described_class::MAX_CITATIONS + 2).times do |i|
        create(:note, project: project, organisation: organisation, title: "Notiz #{i}")
      end

      result = described_class.execute(args: { q: 'Notiz', per_page: 20 }, context: context)

      expect(JSON.parse(result.content)['data'].size).to eq(described_class::MAX_CITATIONS + 2)
      expect(result.citations.size).to eq(described_class::MAX_CITATIONS)
    end
  end
end
