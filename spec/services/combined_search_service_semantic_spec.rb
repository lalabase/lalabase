# frozen_string_literal: true

require 'rails_helper'

# Regression guard for the coupling distance function <-> vector index in the
# semantic search path: idx_ce_fragment_1536_l2 (the 4a HNSW index on the
# content_embeddings sidecar) uses vector_l2_ops, so the DB-side sorting must use
# euclidean ('<->') — like PromptBuildingService and
# Lalabase::ProjectRag::Retriever#fetch_content. A cosine query ('<=>') runs
# past the index (Seq Scan over all of the org's vectors) and is silently slow.
# The Ruby-side threshold filter still computes cosine similarity; for the
# normalized OpenAI embeddings the ranking of both distances is identical.
#
# Since embedding v2 PR 4b retrieval reads the sidecar, so the seed helper must
# mirror each fragment's vector into content_embeddings (mirror_embedding_to_sidecar)
# — inline-only seeds would find nothing at all.
RSpec.describe CombinedSearchService do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  let(:standard_role) do
    create(:role, title: 'Standard User', organisation: organisation, is_default: true)
  end

  let(:user) do
    u = create(:user)
    create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
    u
  end

  let(:query_embedding) { unit_vector(0) }

  before do
    ActsAsTenant.current_tenant = organisation
    stub_default_embedding_space
    pin_exact_vector_scans
    create(:project_permission, user: user, project: project, tickets_access: 'read_only')
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  # 1536-dimensional unit vector with 1.0 at the given position —
  # normalized like the production embeddings, so that cosine and euclidean
  # produce the same ranking.
  def unit_vector(position)
    Array.new(1536, 0.0).tap { |v| v[position] = 1.0 }
  end

  # Fragment as production has it: the record plus the sidecar row the reader queries.
  def embedded_fragment(embedding, content)
    ticket = create(:ticket, project: project, organisation: organisation, creator: user)
    fragment = create(:fragment, fragmentable: ticket, organisation: organisation,
                                 plain_text_content: content)
    seed_sidecar_embedding(fragment, vector: embedding)
    fragment
  end

  # Normalized vector with cosine similarity p to the query (unit_vector(0)):
  # [p, sqrt(1-p²), 0, ...] — allows fragments with graduated similarity.
  def vector_with_similarity(similarity)
    Array.new(1536, 0.0).tap do |v|
      v[0] = similarity
      v[1] = Math.sqrt(1.0 - (similarity**2))
    end
  end

  # The query string DELIBERATELY matches no full text, so that exclusively the
  # semantic path returns results.
  def run_semantic_search(limit: 15)
    described_class.new(
      organisation: organisation,
      query: 'nomatchfulltextterm',
      embedding: query_embedding,
      current_user: user,
      limit: limit
    ).call
  end

  it 'findet ähnliche Fragmente und filtert unähnliche über den Cosine-Schwellwert' do
    similar    = embedded_fragment(unit_vector(0), 'gleiche Richtung wie die Query')
    dissimilar = embedded_fragment(unit_vector(1), 'orthogonal zur Query')

    results = run_semantic_search

    expect(results).to include(similar)
    expect(results).not_to include(dissimilar)
  end

  it 'liefert bei mehr Treffern als limit die ÄHNLICHSTEN (Distanz-Reihenfolge bleibt maßgeblich)' do
    best   = embedded_fragment(vector_with_similarity(1.0), 'similarity 1.0')
    second = embedded_fragment(vector_with_similarity(0.95), 'similarity 0.95')
    third  = embedded_fragment(vector_with_similarity(0.85), 'similarity 0.85')

    results = run_semantic_search(limit: 2)

    expect(results).to contain_exactly(best, second)
    expect(results).not_to include(third)
  end

  it 'begrenzt den Kandidaten-Pool DB-seitig per LIMIT (lädt nicht alle Org-Fragmente nach Ruby)' do
    # Without an SQL LIMIT, the semantic search materializes EVERY accessible
    # fragment with an embedding (~12 KB vector each) and computes the similarity in
    # Ruby — memory/runtime grow linearly with the org's data volume.
    embedded_fragment(unit_vector(0), 'gleiche Richtung wie die Query')

    captured = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      captured << sql if sql.include?('<->')
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      run_semantic_search
    end

    expect(captured).not_to be_empty
    captured.each do |nearest_neighbor_sql|
      expect(nearest_neighbor_sql).to match(/LIMIT/i)
    end
  end

  # PR 4b: base_fragment_query goes into the query object as `scope:`. Its
  # includes(:fragmentable) must survive that merge, otherwise every consumer
  # (PowerSearchService#preload_fragmentables, the result renderer) gets an N+1.
  it 'behält das Preload des Scopes (includes(:fragmentable) überlebt den Merge)' do
    embedded_fragment(unit_vector(0), 'gleiche Richtung wie die Query')

    results = run_semantic_search

    expect(results).not_to be_empty
    expect(results.first.association(:fragmentable)).to be_loaded
  end

  it "sortiert DB-seitig per euclidean ('<->'), damit der L2-Index auf der Sidecar nutzbar bleibt" do
    embedded_fragment(unit_vector(0), 'gleiche Richtung wie die Query')

    captured = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      captured << sql if sql.include?('fragments') && (sql.include?('<->') || sql.include?('<=>'))
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      run_semantic_search
    end

    expect(captured).not_to be_empty
    nearest_neighbor_sql = captured.join("\n")
    expect(nearest_neighbor_sql).to include('<->')
    expect(nearest_neighbor_sql).not_to include('<=>')
  end
end
