# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PowerSearchService, type: :service do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }
  let(:fake_embedding) { Array.new(1536) { 0.1 } }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
    # Since PR 5 the similarity vectors come from the SIDECAR, not from the inline
    # fragments.embedding column — so the org's current space has to resolve (without
    # a credential it raises MissingCredentialError). Unreachable in production: the
    # query embedding runs through the SAME resolution milliseconds earlier, and its
    # failure already switches the search to full-text-only (question_embedding nil →
    # no fetch at all).
    stub_default_embedding_space
  end

  # --- Factory helpers ---

  def create_document_version(document:, title: 'Doc Title')
    version = build(:document_version, document: document, organisation: organisation, title: title, create_embeddings: false)
    version.document_version_file.attach(
      io: StringIO.new('test content'),
      filename: 'test.txt',
      content_type: 'text/plain'
    )
    version.save!
    version
  end

  def create_documentation_page(title: 'Deployment Guide', path: 'guide/deploy.md')
    set = create(:documentation_set, project: project, organisation: organisation)
    create(:documentation_page, documentation_set: set, organisation: organisation, title: title, path: path)
  end

  # --- Mocking helpers ---

  def stub_embedding(result = fake_embedding)
    allow(Lalabase::QueryEmbedding).to receive(:embed).and_return(result)
  end

  def stub_embedding_failure(error = StandardError.new('API error'))
    allow(Lalabase::QueryEmbedding).to receive(:embed).and_raise(error)
  end

  def stub_combined_search(fragments, similarity: 0.85)
    combined = instance_double(CombinedSearchService)
    allow(CombinedSearchService).to receive(:new).and_return(combined)
    allow(combined).to receive(:call).and_return(fragments)
    allow(combined).to receive(:calculate_cosine_similarity).and_return(similarity)
    combined
  end

  # Like stub_combined_search, but the similarity is REALLY computed (the production
  # helper, unstubbed) — needed by the PR-5 examples that assert where the vector
  # comes from, which a constant-returning stub would hide entirely.
  def stub_combined_search_with_real_similarity(fragments)
    real = CombinedSearchService.new(organisation: organisation, query: 'q',
                                     embedding: nil, current_user: user)
    combined = instance_double(CombinedSearchService)
    allow(CombinedSearchService).to receive(:new).and_return(combined)
    allow(combined).to receive(:call).and_return(fragments)
    allow(combined).to receive(:calculate_cosine_similarity) do |vec_a, vec_b|
      real.calculate_cosine_similarity(vec_a, vec_b)
    end
    combined
  end

  def stub_highlights(highlight_map = {})
    highlighted = highlight_map.map do |id, text|
      double('highlighted_fragment', id: id, pg_search_highlight: text)
    end
    scope = double('highlight_scope')
    allow(scope).to receive(:with_pg_search_highlight).and_return(scope)
    allow(scope).to receive(:where).and_return(highlighted)
    allow(Fragment).to receive(:search_full_text_with_highlight_german).and_return(scope)
    allow(Fragment).to receive(:search_full_text_with_highlight_english).and_return(scope)
  end

  # --- #execute ---

  describe '#execute' do
    # GDPR AI opt-in (audit 2026-07-03): search is a core feature and must keep
    # working for a non-opted-in org (the default state) — full-text only, no
    # exception, and NO warn-level logging (an expected policy state is not a
    # failure; before this contract every search warn-spammed the logs).
    # Deliberately NOT stubbing QueryEmbedding: the real factory gate must fire.
    context 'when the organisation has not opted in to AI (GDPR gate)' do
      let(:ticket) { create(:ticket, project: project, organisation: organisation, title: 'Search Target') }
      let!(:fragment) { create(:fragment, fragmentable: ticket, plain_text_content: 'searchable', organisation: organisation) }

      before do
        organisation.update!(ai_enabled: false)
        stub_combined_search([fragment])
        stub_highlights(fragment.id => 'highlighted')
      end

      it 'degrades to full-text search without raising and passes a nil embedding' do
        expect(Rails.logger).not_to receive(:warn)

        results = described_class.new('searchable', organisation, project.id, user).execute

        expect(results).to be_an(Array)
        expect(CombinedSearchService).to have_received(:new).with(hash_including(embedding: nil))
      end
    end

    context 'with successful embedding generation' do
      let(:ticket) { create(:ticket, project: project, organisation: organisation, title: 'Search Target') }
      let!(:fragment) { create(:fragment, fragmentable: ticket, plain_text_content: 'searchable', organisation: organisation) }

      before do
        stub_embedding
        stub_combined_search([fragment])
        stub_highlights(fragment.id => '<mark>searchable</mark>')
      end

      it 'returns an array of result hashes' do
        results = described_class.new('searchable', organisation, project.id, user).execute
        expect(results).to be_an(Array)
        expect(results.size).to eq(1)
      end

      it 'returns results with correct structure' do
        result = described_class.new('searchable', organisation, project.id, user).execute.first

        expect(result).to include(
          type: 'Ticket',
          title: 'Search Target',
          similarity: 0.85,
          highlighted_content: '<mark>searchable</mark>',
          highlight: '<mark>searchable</mark>'
        )
        expect(result[:link]).to be_present
        expect(result[:project_name]).to eq(project.name)
        expect(result[:project_link]).to be_present
        expect(result[:match_types]).to be_an(Array)
        expect(result[:match_type]).to be_a(String)
      end

      it 'passes the query and organisation to QueryEmbedding' do
        described_class.new('test query', organisation, project.id, user).execute
        expect(Lalabase::QueryEmbedding).to have_received(:embed).with('test query', organisation)
      end

      it 'passes multi-word weights for queries with spaces' do
        described_class.new('test query', organisation, project.id, user).execute
        expect(CombinedSearchService).to have_received(:new).with(
          hash_including(fulltext_weight: 0.4, semantic_weight: 0.6)
        )
      end

      it 'passes single-word weights for queries without spaces' do
        described_class.new('test', organisation, project.id, user).execute
        expect(CombinedSearchService).to have_received(:new).with(
          hash_including(fulltext_weight: 0.7, semantic_weight: 0.3)
        )
      end

      it 'passes all required params to CombinedSearchService' do
        described_class.new('query', organisation, project.id, user).execute
        expect(CombinedSearchService).to have_received(:new).with(
          organisation: organisation,
          query: 'query',
          embedding: fake_embedding,
          current_user: user,
          fulltext_weight: a_kind_of(Float),
          semantic_weight: a_kind_of(Float),
          limit: 15,
          similarity_threshold: 0.81,
          project_id: project.id
        )
      end
    end

    context 'when embedding generation fails' do
      let(:ticket) { create(:ticket, project: project, organisation: organisation) }
      let!(:fragment) { create(:fragment, fragmentable: ticket, organisation: organisation) }

      before do
        stub_embedding_failure
        stub_combined_search([fragment])
        stub_highlights({})
      end

      it 'falls back to nil embedding' do
        described_class.new('query', organisation).execute
        expect(CombinedSearchService).to have_received(:new).with(hash_including(embedding: nil))
      end

      it 'still returns results' do
        results = described_class.new('query', organisation).execute
        expect(results).to be_an(Array)
        expect(results.size).to eq(1)
      end

      it 'logs a warning' do
        allow(Rails.logger).to receive(:warn)
        described_class.new('query', organisation).execute
        expect(Rails.logger).to have_received(:warn).with(/Embedding generation failed.*API error/)
      end
    end

    context 'with empty search results' do
      before do
        stub_embedding
        stub_combined_search([])
        stub_highlights({})
      end

      it 'returns an empty array' do
        expect(described_class.new('nothing', organisation).execute).to eq([])
      end
    end

    context 'when fragments have deleted fragmentable objects' do
      let(:ticket) { create(:ticket, project: project, organisation: organisation) }
      let!(:valid_fragment) { create(:fragment, fragmentable: ticket, organisation: organisation) }
      let(:orphan_ticket) { create(:ticket, project: project, organisation: organisation) }
      let!(:orphan_fragment) { create(:fragment, fragmentable: orphan_ticket, organisation: organisation) }

      before do
        stub_embedding
        stub_highlights({})
        allow(orphan_fragment).to receive(:fragmentable).and_return(nil)
      end

      it 'skips fragments with nil fragmentable' do
        stub_combined_search([orphan_fragment])
        expect(described_class.new('test', organisation).execute).to eq([])
      end

      it 'keeps valid fragments when mixed with orphaned ones' do
        stub_combined_search([valid_fragment, orphan_fragment])
        results = described_class.new('test', organisation).execute
        expect(results.size).to eq(1)
        expect(results.first[:title]).to eq(ticket.title)
      end

      it 'skips entire group when all fragments in it are orphaned' do
        frag2 = create(:fragment, fragmentable: orphan_ticket, organisation: organisation)
        allow(frag2).to receive(:fragmentable).and_return(nil)
        stub_combined_search([orphan_fragment, frag2])
        expect(described_class.new('test', organisation).execute).to eq([])
      end
    end

    context 'result grouping by fragmentable object' do
      let(:ticket) { create(:ticket, project: project, organisation: organisation, title: 'Grouped') }
      let!(:fragment1) { create(:fragment, fragmentable: ticket, plain_text_content: 'part 1', organisation: organisation) }
      let!(:fragment2) { create(:fragment, fragmentable: ticket, plain_text_content: 'part 2', organisation: organisation) }

      before do
        stub_embedding
        # Both fragments need a sidecar row: that is the only vector source left.
        seed_sidecar_embedding(fragment1, vector: Array.new(1536, 0.1))
        seed_sidecar_embedding(fragment2, vector: Array.new(1536, 0.2))
      end

      # The vector each similarity is computed on comes from the SIDECAR
      # (PowerSearchService#sidecar_vectors_for) — since PR 7 there is nowhere else it
      # could come from, so the stubs must match those rows, not the record.
      def stub_similarities(combined, low:, high:)
        allow(combined).to receive(:calculate_cosine_similarity)
          .with(vector_for(fragment1), fake_embedding).and_return(low)
        allow(combined).to receive(:calculate_cosine_similarity)
          .with(vector_for(fragment2), fake_embedding).and_return(high)
      end

      def vector_for(fragment)
        ContentEmbedding.find_by(embeddable: fragment).embedding
      end

      it 'returns one result per fragmentable object' do
        stub_combined_search([fragment1, fragment2])
        stub_highlights({})
        results = described_class.new('content', organisation).execute
        expect(results.size).to eq(1)
        expect(results.first[:title]).to eq('Grouped')
      end

      it 'selects the best fragment by cosine similarity' do
        combined = instance_double(CombinedSearchService)
        allow(CombinedSearchService).to receive(:new).and_return(combined)
        allow(combined).to receive(:call).and_return([fragment1, fragment2])
        stub_similarities(combined, low: 0.6, high: 0.9)
        stub_highlights({})

        results = described_class.new('content', organisation).execute
        expect(results.first[:similarity]).to eq(0.9)
      end

      it 'uses first available highlight even if not from best fragment' do
        combined = instance_double(CombinedSearchService)
        allow(CombinedSearchService).to receive(:new).and_return(combined)
        allow(combined).to receive(:call).and_return([fragment1, fragment2])
        stub_similarities(combined, low: 0.6, high: 0.9)
        stub_highlights(fragment1.id => '<mark>from first</mark>')

        results = described_class.new('content', organisation).execute
        expect(results.first[:highlighted_content]).to eq('<mark>from first</mark>')
      end
    end

    context 'match type detection' do
      let(:ticket) { create(:ticket, project: project, organisation: organisation) }
      let!(:fragment) { create(:fragment, fragmentable: ticket, organisation: organisation) }

      before { stub_embedding }

      it 'detects fulltext match when highlight exists' do
        stub_combined_search([fragment], similarity: 0.5)
        stub_highlights(fragment.id => '<mark>match</mark>')
        result = described_class.new('test', organisation).execute.first
        expect(result[:match_types]).to eq(['Volltext Treffer'])
      end

      it 'detects semantic match when similarity >= threshold' do
        stub_combined_search([fragment], similarity: 0.75)
        stub_highlights({})
        result = described_class.new('test', organisation).execute.first
        expect(result[:match_types]).to eq(['Semantischer Treffer'])
      end

      it 'detects both match types when both conditions met' do
        stub_combined_search([fragment], similarity: 0.75)
        stub_highlights(fragment.id => '<mark>match</mark>')
        result = described_class.new('test', organisation).execute.first
        expect(result[:match_types]).to contain_exactly('Volltext Treffer', 'Semantischer Treffer')
      end

      it 'falls back to unknown when neither condition met' do
        stub_combined_search([fragment], similarity: 0.5)
        stub_highlights({})
        result = described_class.new('test', organisation).execute.first
        expect(result[:match_types]).to eq(['Unbekannter Treffer'])
      end

      it 'sets match_type to first match_types entry for backwards compat' do
        stub_combined_search([fragment], similarity: 0.75)
        stub_highlights(fragment.id => '<mark>match</mark>')
        result = described_class.new('test', organisation).execute.first
        expect(result[:match_type]).to eq(result[:match_types].first)
      end

      it 'detects semantic match at exact threshold boundary (0.7)' do
        stub_combined_search([fragment], similarity: 0.7)
        stub_highlights({})
        result = described_class.new('test', organisation).execute.first
        expect(result[:match_types]).to include('Semantischer Treffer')
      end

      it 'does not detect semantic match just below threshold' do
        stub_combined_search([fragment], similarity: 0.6999)
        stub_highlights({})
        result = described_class.new('test', organisation).execute.first
        expect(result[:match_types]).not_to include('Semantischer Treffer')
      end
    end

    context 'sorting by similarity' do
      let(:ticket1) { create(:ticket, project: project, organisation: organisation, title: 'Less Similar') }
      let(:ticket2) { create(:ticket, project: project, organisation: organisation, title: 'More Similar') }
      let!(:frag1) { create(:fragment, fragmentable: ticket1, organisation: organisation) }
      let!(:frag2) { create(:fragment, fragmentable: ticket2, organisation: organisation) }

      before { stub_embedding }

      it 'sorts results by similarity descending' do
        combined = instance_double(CombinedSearchService)
        allow(CombinedSearchService).to receive(:new).and_return(combined)
        allow(combined).to receive(:call).and_return([frag1, frag2])
        # Sequential returns: first call (frag1) → 0.6, second call (frag2) → 0.9
        allow(combined).to receive(:calculate_cosine_similarity).and_return(0.6, 0.9)
        stub_highlights({})

        results = described_class.new('test', organisation).execute
        expect(results.map { |r| r[:title] }).to eq(['More Similar', 'Less Similar'])
      end
    end

    context 'with different fragmentable types' do
      before { stub_embedding }

      it 'handles Note type' do
        note = create(:note, project: project, organisation: organisation, title: 'Test Note', create_embeddings: false)
        fragment = create(:fragment, fragmentable: note, organisation: organisation)
        stub_combined_search([fragment])
        stub_highlights({})

        result = described_class.new('test', organisation).execute.first
        expect(result[:type]).to eq('Note')
        expect(result[:title]).to eq('Test Note')
      end

      it 'handles Ticket type' do
        ticket = create(:ticket, project: project, organisation: organisation, title: 'Test Ticket')
        fragment = create(:fragment, fragmentable: ticket, organisation: organisation)
        stub_combined_search([fragment])
        stub_highlights({})

        result = described_class.new('test', organisation).execute.first
        expect(result[:type]).to eq('Ticket')
        expect(result[:title]).to eq('Test Ticket')
      end

      it 'handles Post type' do
        ticket = create(:ticket, project: project, organisation: organisation, title: 'Post Ticket')
        post_record = create(:post, ticket: ticket, user: user, organisation: organisation, create_embeddings: false)
        fragment = create(:fragment, fragmentable: post_record, organisation: organisation)
        stub_combined_search([fragment])
        stub_highlights({})

        result = described_class.new('test', organisation).execute.first
        expect(result[:type]).to eq('Post')
        expect(result[:title]).to eq('Post Ticket')
      end

      it 'handles DocumentVersion type' do
        document = create(:document, project: project, organisation: organisation)
        version = create_document_version(document: document, title: 'Doc Title')
        document.update!(current_version: version)
        fragment = create(:fragment, fragmentable: version, organisation: organisation)
        stub_combined_search([fragment])
        stub_highlights({})

        result = described_class.new('test', organisation).execute.first
        expect(result[:type]).to eq('Dokument')
        expect(result[:title]).to eq('Doc Title')
      end

      it 'handles DocumentationPage type' do
        page = create_documentation_page(title: 'Deployment Guide')
        fragment = create(:fragment, fragmentable: page, organisation: organisation)
        stub_combined_search([fragment])
        stub_highlights({})

        result = described_class.new('test', organisation).execute.first
        expect(result[:type]).to eq('Dokumentation')
        expect(result[:title]).to eq('Deployment Guide')
      end
    end

    context 'optional parameters' do
      let(:ticket) { create(:ticket, project: project, organisation: organisation) }
      let!(:fragment) { create(:fragment, fragmentable: ticket, organisation: organisation) }

      before do
        stub_embedding
        stub_combined_search([fragment])
        stub_highlights({})
      end

      it 'works without project_id' do
        described_class.new('query', organisation, nil, user).execute
        expect(CombinedSearchService).to have_received(:new).with(hash_including(project_id: nil))
      end

      it 'works without current_user' do
        described_class.new('query', organisation, project.id).execute
        expect(CombinedSearchService).to have_received(:new).with(hash_including(current_user: nil))
      end

      it 'works with only query and organisation' do
        results = described_class.new('query', organisation).execute
        expect(results).to be_an(Array)
      end
    end
  end

  # --- Private method unit tests ---

  describe '#dynamic_weights (private)' do
    subject(:service) { described_class.new('q', organisation) }

    it 'returns fulltext-heavy weights for single-word queries' do
      expect(service.send(:dynamic_weights, 'singleword')).to eq(fulltext_weight: 0.7, semantic_weight: 0.3)
    end

    it 'returns semantic-heavy weights for multi-word queries' do
      expect(service.send(:dynamic_weights, 'multiple words')).to eq(fulltext_weight: 0.4, semantic_weight: 0.6)
    end

    it 'treats trailing space as multi-word' do
      expect(service.send(:dynamic_weights, 'word ')).to eq(fulltext_weight: 0.4, semantic_weight: 0.6)
    end

    it 'treats empty string as single-word' do
      expect(service.send(:dynamic_weights, '')).to eq(fulltext_weight: 0.7, semantic_weight: 0.3)
    end
  end

  describe '#result_type (private)' do
    subject(:service) { described_class.new('q', organisation) }

    it('maps Note')              { expect(service.send(:result_type, 'Note')).to eq('Note') }
    it('maps DocumentVersion')   { expect(service.send(:result_type, 'DocumentVersion')).to eq('Dokument') }
    it('maps DocumentationPage') { expect(service.send(:result_type, 'DocumentationPage')).to eq('Dokumentation') }
    it('maps Post')              { expect(service.send(:result_type, 'Post')).to eq('Post') }
    it('maps Ticket')            { expect(service.send(:result_type, 'Ticket')).to eq('Ticket') }
    it('maps MeetingAnalysis')   { expect(service.send(:result_type, 'MeetingAnalysis')).to eq('Analyse') }
    it('maps unknown')           { expect(service.send(:result_type, 'FooBar')).to eq('Unknown') }
  end

  describe '#result_title (private)' do
    subject(:service) { described_class.new('q', organisation) }

    context 'with Note' do
      it 'returns the note title' do
        note = create(:note, project: project, organisation: organisation, title: 'My Note', create_embeddings: false)
        fragment = create(:fragment, fragmentable: note, organisation: organisation)
        expect(service.send(:result_title, fragment)).to eq('My Note')
      end

      it 'returns fallback when fragmentable is nil' do
        fragment = double('fragment', fragmentable_type: 'Note', fragmentable: nil)
        expect(service.send(:result_title, fragment)).to eq('Note (deleted)')
      end
    end

    context 'with DocumentVersion' do
      it 'returns the document title' do
        document = create(:document, project: project, organisation: organisation)
        version = create_document_version(document: document, title: 'Doc Title')
        document.update!(current_version: version)
        fragment = create(:fragment, fragmentable: version, organisation: organisation)
        expect(service.send(:result_title, fragment)).to eq('Doc Title')
      end

      it 'returns fallback when fragmentable is nil' do
        fragment = double('fragment', fragmentable_type: 'DocumentVersion', fragmentable: nil)
        expect(service.send(:result_title, fragment)).to eq('Document (deleted)')
      end

      it 'returns fallback when document is nil' do
        version = double('document_version', document: nil)
        fragment = double('fragment', fragmentable_type: 'DocumentVersion', fragmentable: version)
        expect(service.send(:result_title, fragment)).to eq('Document (deleted)')
      end
    end

    context 'with DocumentationPage' do
      it 'returns the page title' do
        page = create_documentation_page(title: 'Deployment Guide')
        fragment = create(:fragment, fragmentable: page, organisation: organisation)
        expect(service.send(:result_title, fragment)).to eq('Deployment Guide')
      end

      it 'falls back to the path when the title is blank' do
        page = create_documentation_page(title: nil, path: 'guide/no-title.md')
        fragment = create(:fragment, fragmentable: page, organisation: organisation)
        expect(service.send(:result_title, fragment)).to eq('guide/no-title.md')
      end

      it 'returns fallback when fragmentable is nil' do
        fragment = double('fragment', fragmentable_type: 'DocumentationPage', fragmentable: nil)
        expect(service.send(:result_title, fragment)).to eq('Dokumentation (deleted)')
      end
    end

    context 'with Post' do
      it 'returns the ticket title' do
        ticket = create(:ticket, project: project, organisation: organisation, title: 'Post Ticket')
        post_record = create(:post, ticket: ticket, user: user, organisation: organisation, create_embeddings: false)
        fragment = create(:fragment, fragmentable: post_record, organisation: organisation)
        expect(service.send(:result_title, fragment)).to eq('Post Ticket')
      end

      it 'returns fallback when fragmentable is nil' do
        fragment = double('fragment', fragmentable_type: 'Post', fragmentable: nil)
        expect(service.send(:result_title, fragment)).to eq('Ticket (deleted)')
      end

      it 'returns fallback when ticket is nil' do
        post_record = double('post', ticket: nil)
        fragment = double('fragment', fragmentable_type: 'Post', fragmentable: post_record)
        expect(service.send(:result_title, fragment)).to eq('Ticket (deleted)')
      end
    end

    context 'with Ticket' do
      it 'returns the ticket title' do
        ticket = create(:ticket, project: project, organisation: organisation, title: 'My Ticket')
        fragment = create(:fragment, fragmentable: ticket, organisation: organisation)
        expect(service.send(:result_title, fragment)).to eq('My Ticket')
      end

      it 'returns fallback when fragmentable is nil' do
        fragment = double('fragment', fragmentable_type: 'Ticket', fragmentable: nil)
        expect(service.send(:result_title, fragment)).to eq('Ticket (deleted)')
      end
    end

    context 'with MeetingAnalysis' do
      it 'returns the prompt title' do
        meeting = create(:meeting, project: project, organisation: organisation)
        analysis = create(:meeting_analysis, meeting: meeting, organisation: organisation, prompt_title: 'Entscheidungen')
        fragment = create(:fragment, fragmentable: analysis, organisation: organisation)
        expect(service.send(:result_title, fragment)).to eq('Entscheidungen')
      end

      it 'returns fallback when fragmentable is nil' do
        fragment = double('fragment', fragmentable_type: 'MeetingAnalysis', fragmentable: nil)
        expect(service.send(:result_title, fragment)).to eq('Analyse (deleted)')
      end
    end

    context 'with unknown type' do
      it 'returns Unknown' do
        fragment = double('fragment', fragmentable_type: 'Unknown')
        expect(service.send(:result_title, fragment)).to eq('Unknown')
      end
    end
  end

  describe '#result_link (private)' do
    subject(:service) { described_class.new('q', organisation) }
    let(:helpers) { Rails.application.routes.url_helpers }

    context 'with Note' do
      it 'returns the notes path' do
        note = create(:note, project: project, organisation: organisation, create_embeddings: false)
        fragment = create(:fragment, fragmentable: note, organisation: organisation)
        expected = helpers.organisation_project_notes_path(organisation, project, note_id: note.id)
        expect(service.send(:result_link, fragment)).to eq(expected)
      end

      it 'returns # when project is nil' do
        note = double('note', project: nil, id: SecureRandom.uuid)
        fragment = double('fragment', fragmentable_type: 'Note', fragmentable: note)
        expect(service.send(:result_link, fragment)).to eq('#')
      end
    end

    context 'with DocumentVersion' do
      it 'returns the document path' do
        document = create(:document, project: project, organisation: organisation)
        version = create_document_version(document: document)
        fragment = create(:fragment, fragmentable: version, organisation: organisation)
        expected = helpers.organisation_project_document_path(organisation, project, document)
        expect(service.send(:result_link, fragment)).to eq(expected)
      end

      it 'returns # when document is nil' do
        version = double('document_version', document: nil)
        fragment = double('fragment', fragmentable_type: 'DocumentVersion', fragmentable: version)
        expect(service.send(:result_link, fragment)).to eq('#')
      end

      it 'returns # when document.project is nil' do
        doc = double('document', project: nil)
        version = double('document_version', document: doc)
        fragment = double('fragment', fragmentable_type: 'DocumentVersion', fragmentable: version)
        expect(service.send(:result_link, fragment)).to eq('#')
      end
    end

    context 'with DocumentationPage' do
      it 'returns the documentation index path with set and page params' do
        page = create_documentation_page(path: 'guide/deploy.md')
        set = page.documentation_set
        fragment = create(:fragment, fragmentable: page, organisation: organisation)
        expected = helpers.organisation_project_documentation_index_path(
          organisation, project, set_id: set.id, page: 'guide/deploy.md'
        )
        expect(service.send(:result_link, fragment)).to eq(expected)
      end

      it 'returns # when the documentation_set is nil' do
        page = double('documentation_page', documentation_set: nil)
        fragment = double('fragment', fragmentable_type: 'DocumentationPage', fragmentable: page)
        expect(service.send(:result_link, fragment)).to eq('#')
      end

      it 'returns # when the set project is nil' do
        set = double('documentation_set', project: nil)
        page = double('documentation_page', documentation_set: set)
        fragment = double('fragment', fragmentable_type: 'DocumentationPage', fragmentable: page)
        expect(service.send(:result_link, fragment)).to eq('#')
      end
    end

    context 'with Post' do
      it 'returns the ticket path' do
        ticket = create(:ticket, project: project, organisation: organisation)
        post_record = create(:post, ticket: ticket, user: user, organisation: organisation, create_embeddings: false)
        fragment = create(:fragment, fragmentable: post_record, organisation: organisation)
        expected = helpers.organisation_project_ticket_path(organisation, project, ticket)
        expect(service.send(:result_link, fragment)).to eq(expected)
      end

      it 'returns # when ticket is nil' do
        post_record = double('post', ticket: nil)
        fragment = double('fragment', fragmentable_type: 'Post', fragmentable: post_record)
        expect(service.send(:result_link, fragment)).to eq('#')
      end

      it 'returns # when ticket.project is nil' do
        ticket = double('ticket', project: nil)
        post_record = double('post', ticket: ticket)
        fragment = double('fragment', fragmentable_type: 'Post', fragmentable: post_record)
        expect(service.send(:result_link, fragment)).to eq('#')
      end
    end

    context 'with Ticket' do
      it 'returns the ticket path' do
        ticket = create(:ticket, project: project, organisation: organisation)
        fragment = create(:fragment, fragmentable: ticket, organisation: organisation)
        expected = helpers.organisation_project_ticket_path(organisation, project, ticket)
        expect(service.send(:result_link, fragment)).to eq(expected)
      end

      it 'returns # when project is nil' do
        ticket = double('ticket', project: nil)
        fragment = double('fragment', fragmentable_type: 'Ticket', fragmentable: ticket)
        expect(service.send(:result_link, fragment)).to eq('#')
      end
    end

    context 'with MeetingAnalysis' do
      it 'deep-links to the analysis meeting (an analysis has no own page)' do
        meeting = create(:meeting, project: project, organisation: organisation)
        analysis = create(:meeting_analysis, meeting: meeting, organisation: organisation)
        fragment = create(:fragment, fragmentable: analysis, organisation: organisation)
        expected = helpers.organisation_project_meeting_path(organisation, project, meeting)
        expect(service.send(:result_link, fragment)).to eq(expected)
      end

      it 'returns # when the meeting project is nil' do
        meeting = double('meeting', project: nil)
        analysis = double('analysis', meeting: meeting)
        fragment = double('fragment', fragmentable_type: 'MeetingAnalysis', fragmentable: analysis)
        expect(service.send(:result_link, fragment)).to eq('#')
      end
    end

    context 'with unknown type' do
      it 'returns #' do
        fragment = double('fragment', fragmentable_type: 'Unknown')
        expect(service.send(:result_link, fragment)).to eq('#')
      end
    end
  end

  describe '#result_project (private)' do
    subject(:service) { described_class.new('q', organisation) }

    it 'returns the project for Note' do
      note = create(:note, project: project, organisation: organisation, create_embeddings: false)
      fragment = create(:fragment, fragmentable: note, organisation: organisation)
      expect(service.send(:result_project, fragment)).to eq(project)
    end

    it 'returns the project for Ticket' do
      ticket = create(:ticket, project: project, organisation: organisation)
      fragment = create(:fragment, fragmentable: ticket, organisation: organisation)
      expect(service.send(:result_project, fragment)).to eq(project)
    end

    it 'returns the project via ticket for Post' do
      ticket = create(:ticket, project: project, organisation: organisation)
      post_record = create(:post, ticket: ticket, user: user, organisation: organisation, create_embeddings: false)
      fragment = create(:fragment, fragmentable: post_record, organisation: organisation)
      expect(service.send(:result_project, fragment)).to eq(project)
    end

    it 'returns the project via document for DocumentVersion' do
      document = create(:document, project: project, organisation: organisation)
      version = create_document_version(document: document)
      fragment = create(:fragment, fragmentable: version, organisation: organisation)
      expect(service.send(:result_project, fragment)).to eq(project)
    end

    it 'returns the project via documentation_set for DocumentationPage' do
      page = create_documentation_page
      fragment = create(:fragment, fragmentable: page, organisation: organisation)
      expect(service.send(:result_project, fragment)).to eq(project)
    end

    it 'returns the project via meeting for MeetingAnalysis' do
      meeting = create(:meeting, project: project, organisation: organisation)
      analysis = create(:meeting_analysis, meeting: meeting, organisation: organisation)
      fragment = create(:fragment, fragmentable: analysis, organisation: organisation)
      expect(service.send(:result_project, fragment)).to eq(project)
    end

    it 'returns nil when fragmentable is nil' do
      fragment = double('fragment', fragmentable_type: 'Ticket', fragmentable: nil)
      expect(service.send(:result_project, fragment)).to be_nil
    end

    it 'returns nil when intermediate association is nil' do
      post_record = double('post', ticket: nil)
      fragment = double('fragment', fragmentable_type: 'Post', fragmentable: post_record)
      expect(service.send(:result_project, fragment)).to be_nil
    end

    it 'returns nil for unknown type' do
      fragment = double('fragment', fragmentable_type: 'Unknown')
      expect(service.send(:result_project, fragment)).to be_nil
    end
  end

  describe '#result_content (private)' do
    subject(:service) { described_class.new('q', organisation) }

    it 'returns plain_text_version for Note' do
      note = create(:note, project: project, organisation: organisation, title: 'N', content: 'Note body', create_embeddings: false)
      fragment = create(:fragment, fragmentable: note, organisation: organisation)
      expect(service.send(:result_content, fragment)).to eq(note.plain_text_version)
    end

    it 'returns plain_text_version for Ticket' do
      ticket = create(:ticket, project: project, organisation: organisation, title: 'T', content: 'Ticket body')
      fragment = create(:fragment, fragmentable: ticket, organisation: organisation)
      expect(service.send(:result_content, fragment)).to eq(ticket.plain_text_version)
    end

    it 'returns plain_text_version for DocumentVersion' do
      document = create(:document, project: project, organisation: organisation)
      version = create_document_version(document: document)
      fragment = create(:fragment, fragmentable: version, organisation: organisation)
      expect(service.send(:result_content, fragment)).to eq(version.plain_text_version)
    end

    it 'returns plain_text_version for DocumentationPage' do
      page = create_documentation_page
      fragment = create(:fragment, fragmentable: page, organisation: organisation)
      expect(service.send(:result_content, fragment)).to eq(page.plain_text_version)
    end

    it 'returns content for Post' do
      ticket = create(:ticket, project: project, organisation: organisation)
      post_record = create(:post, ticket: ticket, user: user, organisation: organisation, content: 'Post body', create_embeddings: false)
      fragment = create(:fragment, fragmentable: post_record, organisation: organisation)
      expect(service.send(:result_content, fragment)).to eq(post_record.content)
    end

    it 'returns plain_text_version for MeetingAnalysis' do
      meeting = create(:meeting, project: project, organisation: organisation)
      analysis = create(:meeting_analysis, meeting: meeting, organisation: organisation, content: 'Analysis body')
      fragment = create(:fragment, fragmentable: analysis, organisation: organisation)
      expect(service.send(:result_content, fragment)).to eq(analysis.plain_text_version)
    end

    it 'returns empty string for unknown type' do
      fragment = double('fragment', fragmentable_type: 'Unknown')
      expect(service.send(:result_content, fragment)).to eq('')
    end
  end

  describe '#highlight_fragments (private)' do
    subject(:service) { described_class.new('query', organisation) }
    let(:ticket) { create(:ticket, project: project, organisation: organisation) }
    let!(:fragment) { create(:fragment, fragmentable: ticket, organisation: organisation) }

    it 'combines german and english highlights' do
      other_id = SecureRandom.uuid
      german_result = double('german', id: fragment.id, pg_search_highlight: '<mark>german</mark>')
      english_result = double('english', id: other_id, pg_search_highlight: '<mark>english</mark>')

      german_scope = double('gs')
      allow(german_scope).to receive(:with_pg_search_highlight).and_return(german_scope)
      allow(german_scope).to receive(:where).and_return([german_result])

      english_scope = double('es')
      allow(english_scope).to receive(:with_pg_search_highlight).and_return(english_scope)
      allow(english_scope).to receive(:where).and_return([english_result])

      allow(Fragment).to receive(:search_full_text_with_highlight_german).and_return(german_scope)
      allow(Fragment).to receive(:search_full_text_with_highlight_english).and_return(english_scope)

      result = service.send(:highlight_fragments, [fragment], 'query')
      expect(result[fragment.id]).to eq('<mark>german</mark>')
      expect(result[other_id]).to eq('<mark>english</mark>')
    end

    it 'deduplicates results appearing in both languages' do
      shared = double('shared', id: fragment.id, pg_search_highlight: '<mark>shared</mark>')
      scope = double('scope')
      allow(scope).to receive(:with_pg_search_highlight).and_return(scope)
      allow(scope).to receive(:where).and_return([shared])
      allow(Fragment).to receive(:search_full_text_with_highlight_german).and_return(scope)
      allow(Fragment).to receive(:search_full_text_with_highlight_english).and_return(scope)

      result = service.send(:highlight_fragments, [fragment], 'query')
      expect(result.size).to eq(1)
    end

    it 'returns empty hash when no highlights found' do
      scope = double('scope')
      allow(scope).to receive(:with_pg_search_highlight).and_return(scope)
      allow(scope).to receive(:where).and_return([])
      allow(Fragment).to receive(:search_full_text_with_highlight_german).and_return(scope)
      allow(Fragment).to receive(:search_full_text_with_highlight_english).and_return(scope)

      expect(service.send(:highlight_fragments, [fragment], 'query')).to eq({})
    end

    it 'passes fragment ids to the where clause' do
      scope = double('scope')
      allow(scope).to receive(:with_pg_search_highlight).and_return(scope)
      allow(scope).to receive(:where).and_return([])
      allow(Fragment).to receive(:search_full_text_with_highlight_german).and_return(scope)
      allow(Fragment).to receive(:search_full_text_with_highlight_english).and_return(scope)

      service.send(:highlight_fragments, [fragment], 'query')
      expect(scope).to have_received(:where).with(id: [fragment.id]).twice
    end
  end

  describe '#determine_match_types (private)' do
    subject(:service) { described_class.new('q', organisation) }

    let(:fid) { SecureRandom.uuid }
    let(:fragments) { [double('fragment', id: fid)] }

    it 'returns fulltext when highlight exists' do
      expect(service.send(:determine_match_types, fragments, { fid => '<mark>x</mark>' }, { fid => 0.5 }))
        .to eq(['Volltext Treffer'])
    end

    it 'returns semantic when similarity >= threshold' do
      expect(service.send(:determine_match_types, fragments, {}, { fid => 0.7 }))
        .to eq(['Semantischer Treffer'])
    end

    it 'returns both when both conditions met' do
      expect(service.send(:determine_match_types, fragments, { fid => '<mark>x</mark>' }, { fid => 0.8 }))
        .to contain_exactly('Volltext Treffer', 'Semantischer Treffer')
    end

    it 'returns unknown when neither condition met' do
      expect(service.send(:determine_match_types, fragments, {}, { fid => 0.3 }))
        .to eq(['Unbekannter Treffer'])
    end
  end

  describe '#build_result (private)' do
    subject(:service) { described_class.new('q', organisation) }
    let(:ticket) { create(:ticket, project: project, organisation: organisation, title: 'Build Test') }
    let!(:fragment) { create(:fragment, fragmentable: ticket, organisation: organisation) }

    it 'returns hash with all required keys' do
      result = service.send(:build_result, fragment, 0.85, '<mark>x</mark>', ['Volltext Treffer'])
      expect(result.keys).to contain_exactly(
        :type, :title, :link, :project_name, :project_link, :content,
        :highlighted_content, :similarity, :match_types, :match_type, :highlight
      )
    end

    it 'includes project name and link' do
      result = service.send(:build_result, fragment, 0.85, nil, ['Volltext Treffer'])
      expect(result[:project_name]).to eq(project.name)
      expect(result[:project_link]).to eq(
        Rails.application.routes.url_helpers.organisation_project_path(organisation, project)
      )
    end

    it 'sets project keys to nil when project is missing' do
      orphan = double('ticket', title: 'Orphan', project: nil, plain_text_version: '')
      orphan_fragment = double('fragment', fragmentable_type: 'Ticket', fragmentable: orphan)
      result = service.send(:build_result, orphan_fragment, 0.5, nil, ['Unbekannter Treffer'])
      expect(result[:project_name]).to be_nil
      expect(result[:project_link]).to be_nil
    end

    it 'sets highlight equal to highlighted_content' do
      result = service.send(:build_result, fragment, 0.85, '<mark>x</mark>', ['Volltext Treffer'])
      expect(result[:highlight]).to eq(result[:highlighted_content])
    end

    it 'sets match_type to first element of match_types' do
      result = service.send(:build_result, fragment, 0.85, nil, %w[A B])
      expect(result[:match_type]).to eq('A')
    end

    it 'handles nil highlighted_content' do
      result = service.send(:build_result, fragment, 0.5, nil, ['Unbekannter Treffer'])
      expect(result[:highlighted_content]).to be_nil
      expect(result[:highlight]).to be_nil
    end
  end

  describe 'constants' do
    it('SIMILARITY_THRESHOLD') { expect(described_class::SIMILARITY_THRESHOLD).to eq(0.81) }
    it('SEMANTIC_THRESHOLD')   { expect(described_class::SEMANTIC_THRESHOLD).to eq(0.7) }
    it('LIMIT')                { expect(described_class::LIMIT).to eq(15) }
  end

  # The banner's own promise. Since the fragment/embedding split the degraded hint says
  # "Alles, was deine Suchwörter enthält, wird weiterhin gefunden" — a specific claim
  # about RESULTS, where the old wording only named a missing feature. Every example in
  # the group below stubs CombinedSearchService to return [], so they pin the FLAG and
  # would stay green over a search that had quietly stopped returning anything.
  #
  # Before the split the promise would have been false anyway: no embedding meant no
  # fragment, so the content was missing from the full-text index too. It is true now,
  # and a sentence in the interface that nothing tests is a sentence waiting to rot.
  describe 'the degraded search still returns full-text hits' do
    let(:ticket) { create(:ticket, project: project, organisation: organisation, title: 'Quastenflosser') }
    let!(:fragment) do
      create(:fragment, fragmentable: ticket, plain_text_content: 'Quastenflosser', organisation: organisation)
    end

    it 'flags the degradation AND hands back the hit it promises' do
      stub_embedding_failure(Lalabase::Llm::Provider::RateLimitError.new('429'))
      stub_combined_search([fragment])
      stub_highlights(fragment.id => 'Quastenflosser')

      service = described_class.new('Quastenflosser', organisation, project.id, user)
      results = service.execute

      expect(service.semantic_degraded?).to be(true)
      expect(results).not_to be_empty
    end
  end

  # S3 §4.6 (test 26): search degrades to full-text without the semantic layer, and
  # flags it so the UI can show the "ohne KI-Ranking" hint.
  describe '#semantic_degraded?' do
    it 'is false on a normal semantic search' do
      stub_embedding
      allow(CombinedSearchService).to receive(:new).and_return(instance_double(CombinedSearchService, call: []))
      service = described_class.new('query', organisation, nil, user)
      service.execute
      expect(service.semantic_degraded?).to be(false)
    end

    it 'is true (full-text fallback) when the quota is exhausted' do
      stub_embedding_failure(Lalabase::Llm::QuotaExceededError.new('exhausted'))
      allow(CombinedSearchService).to receive(:new).and_return(instance_double(CombinedSearchService, call: []))
      service = described_class.new('query', organisation, nil, user)
      expect { service.execute }.not_to raise_error
      expect(service.semantic_degraded?).to be(true)
    end

    it 'is true when AI is disabled for the org' do
      stub_embedding_failure(Lalabase::Llm::AiDisabledError.new('off'))
      allow(CombinedSearchService).to receive(:new).and_return(instance_double(CombinedSearchService, call: []))
      service = described_class.new('query', organisation, nil, user)
      service.execute
      expect(service.semantic_degraded?).to be(true)
    end
  end

  # Gespräche Slice 6: Meeting fragments flow into the power search via
  # CombinedSearchService — the presentation layer must know the type, or a hit
  # renders as "Unknown" with a dead '#' link (review PR #247, enum completeness).
  describe 'meeting results (Gespräche Slice 6)' do
    let(:meeting) do
      create(:meeting, project: project, organisation: organisation, creator: user,
                       title: 'Kickoff-Gespräch', notes: 'Besprochen wurde die Preisliste.',
                       create_embeddings: true)
    end
    let!(:fragment) do
      create(:fragment, fragmentable: meeting, plain_text_content: 'Preisliste', organisation: organisation)
    end

    before do
      stub_embedding
      stub_combined_search([fragment])
      stub_highlights(fragment.id => '<mark>Preisliste</mark>')
    end

    it 'builds a fully-shaped meeting result (type, title, project, deep link, content)' do
      result = described_class.new('Preisliste', organisation, project.id, user).execute.first

      # 'Meeting', not 'Gespräch': the German UI term was settled as Meeting(s) and the search
      # result type follows the UI. This assertion kept the pre-rename wording.
      expect(result).to include(type: 'Meeting', title: 'Kickoff-Gespräch')
      expect(result[:project_name]).to eq(project.name)
      expect(result[:link]).to include("/meetings/#{meeting.id}")
      expect(result[:content]).to include('Preisliste')
    end
  end

  # Similarity source (embedding v2 PR 5, §3.4.1). This path re-scores the results of
  # CombinedSearchService and used to read the INLINE fragments.embedding column. Since
  # the PR-5 write guard that column is NULL for every non-1536 org, and the helper is
  # fail-soft (nil vector → 0.0), so the ranking of such an org would have collapsed
  # silently to 0.0: no error, "Semantischer Treffer" gone, search degraded to
  # full-text — and the alignment gate cannot see it, because the sidecar rows are
  # perfectly fine. The vector now comes from the sidecar row of the CURRENT space.
  describe 'similarity source (embedding v2 PR 5)' do
    let(:ticket) { create(:ticket, project: project, organisation: organisation, creator: user) }
    let(:query_vector) { Array.new(1536, 0.0).tap { |v| v[0] = 1.0 } }

    before { stub_highlights }

    it 'scores from the sidecar row, not from the inline column' do
      # Inline deliberately carries an ORTHOGONAL vector: if the scoring still read
      # it, the similarity would be 0.0 rather than 1.0.
      fragment = create(:fragment, fragmentable: ticket, organisation: organisation,
                                   plain_text_content: 'x')
      create(:content_embedding, embeddable: fragment, organisation: organisation,
                                 embedding: query_vector, indexed: true)
      stub_embedding(query_vector)
      stub_combined_search_with_real_similarity([fragment])

      result = described_class.new('q', organisation, project.id, user).execute.first

      expect(result[:similarity]).to be_within(1e-6).of(1.0)
      expect(result[:match_types]).to include('Semantischer Treffer')
    end

    # The §2.8 repro: before the fix this org scored 0.0 across the board.
    it 'scores a 1024-dim org from its 1024 sidecar row (inline is NULL there)' do
      space = stub_embedding_space(dims: 1024)
      short_vector = Array.new(1024, 0.0).tap { |v| v[0] = 1.0 }
      # Exactly what the PR-5 write guard produces: no inline vector, sidecar only.
      fragment = create(:fragment, fragmentable: ticket, organisation: organisation,
                                   plain_text_content: 'x')
      create(:content_embedding, embeddable: fragment, organisation: organisation,
                                 embedding: short_vector, indexed: true, **space)
      stub_embedding(short_vector)
      stub_combined_search_with_real_similarity([fragment])

      result = described_class.new('q', organisation, project.id, user).execute.first

      expect(result[:similarity]).to be_within(1e-6).of(1.0)
      expect(result[:match_types]).to include('Semantischer Treffer')
    end

    # Fail-soft is UNCHANGED, only its source moved: a fragment without a row in the
    # current space (mid-reindex, or found by full-text only) scores 0.0, never raises.
    it 'scores 0.0 without raising for a fragment that has no row in the current space' do
      fragment = create(:fragment, fragmentable: ticket, organisation: organisation,
                                   plain_text_content: 'x')
      stub_embedding(query_vector)
      stub_combined_search_with_real_similarity([fragment])

      result = described_class.new('q', organisation, project.id, user).execute.first

      expect(result[:similarity]).to eq(0.0)
      expect(result[:match_types]).to eq(['Unbekannter Treffer'])
    end

    # A row of the OLD space stays indexed: true until PR 6 retires it — it must not
    # be picked up as the current space's vector (that is the reindexer's `stale`).
    it 'ignores a sidecar row from a different space' do
      space = stub_embedding_space(dims: 1024)
      fragment = create(:fragment, fragmentable: ticket, organisation: organisation,
                                   plain_text_content: 'x')
      create(:content_embedding, embeddable: fragment, organisation: organisation,
                                 embedding: query_vector, indexed: true) # 1536 leftover
      stub_embedding(Array.new(1024, 0.0).tap { |v| v[0] = 1.0 })
      stub_combined_search_with_real_similarity([fragment])
      expect(space[:embedding_dims]).to eq(1024)

      expect(described_class.new('q', organisation, project.id, user).execute.first[:similarity]).to eq(0.0)
    end

    # Without a query embedding nothing resolves at all — the fetch (and with it the
    # space resolution that could raise MissingCredentialError) must not even run.
    it 'does not resolve the space when there is no query embedding' do
      fragment = create(:fragment, fragmentable: ticket, organisation: organisation,
                                   plain_text_content: 'x')
      stub_embedding_failure
      stub_combined_search_with_real_similarity([fragment])
      allow(Lalabase::Llm::Factory).to receive(:embedding_space_for).and_call_original

      result = described_class.new('q', organisation, project.id, user).execute.first

      expect(result[:similarity]).to eq(0.0)
      expect(Lalabase::Llm::Factory).not_to have_received(:embedding_space_for)
    end

    # Review finding I1: the lookup sits inside #execute, where every other AI step is
    # rescued. Search is a core feature — a credential deactivated between the query
    # embedding and this lookup must degrade the ranking, not 500 the search page.
    it 'degrades to full-text instead of raising when the space cannot be resolved' do
      fragment = create(:fragment, fragmentable: ticket, organisation: organisation,
                                   plain_text_content: 'x')
      stub_embedding(query_vector)
      stub_combined_search_with_real_similarity([fragment])
      allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
        .and_raise(Lalabase::Llm::Factory::MissingCredentialError, 'gone mid-request')

      service = described_class.new('q', organisation, project.id, user)
      result = nil

      expect { result = service.execute.first }.not_to raise_error
      expect(result[:similarity]).to eq(0.0)
      expect(service).to be_semantic_degraded
    end
  end
end
