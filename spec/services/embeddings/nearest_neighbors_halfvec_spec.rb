# frozen_string_literal: true

require 'rails_helper'

# Embedding v2 PR 5b: retrieval in a 3072-dimensional space.
#
# The two EXPLAIN guards prove the halfvec index is USABLE and that the seam spells the
# matching cast. Neither proves that a 3072 org actually gets sensible RESULTS back — a
# cast can be syntactically right and still order wrongly, and pgvector would not
# complain. So this spec asserts real distances on real rows.
#
# Why the test vectors are shaped the way they are: they are deliberately NOT scalar
# multiples of one another. Scalar multiples are cosine-identical, so an ordering
# assertion built on them passes on float noise alone and would survive almost any
# mutation of the ordering logic. Here the near vector shares most of its mass with the
# query and the far one is orthogonal to it, which separates them under BOTH metrics.
#
# pin_exact_vector_scans for the same reason every other retrieval spec uses it:
# transactional fixtures leave dead HNSW entries behind, which makes index-backed
# retrieval specs a timing race (see the helper's own comment). Index usability is
# pinned by the EXPLAIN guards, correctness of results here.
RSpec.describe 'Embeddings::NearestNeighbors in a 3072 space (PR 5b)' do
  let(:dims) { 3072 }
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  # Mass on the first axis — the query. Near shares that axis, far is orthogonal to it.
  let(:query_vector) { unit_axis(0) }
  let(:near_vector) do
    vector = Array.new(dims, 0.0)
    vector[0] = 0.9
    vector[1] = 0.1
    vector
  end
  let(:far_vector) { unit_axis(1) }

  before do
    ActsAsTenant.current_tenant = organisation
    stub_embedding_space(dims: dims)
    pin_exact_vector_scans
  end

  after { ActsAsTenant.current_tenant = nil }

  def unit_axis(index)
    Array.new(dims) { |i| i == index ? 1.0 : 0.0 }
  end

  # The sidecar row is written directly: the INLINE column is typed vector(1536) and
  # cannot hold 3072 at all (that is exactly what the PR-5 inline write guard enforces),
  # so mirror_embedding_to_sidecar is not applicable in this space.
  def sidecar_fragment(vector, space_dims: dims)
    note = create(:note, project: project, organisation: organisation)
    fragment = create(:fragment, fragmentable: note, organisation: organisation,
                                 plain_text_content: 'inhalt')
    create(:content_embedding,
           embeddable: fragment, organisation: organisation,
           embedding_provider: 'openai_compatible', embedding_model: "test-embed-#{space_dims}",
           embedding_dims: space_dims, embedding: vector, indexed: true)
    fragment
  end

  it 'stores a 3072 vector in the sidecar at full length (CHECK constraint holds)' do
    fragment = sidecar_fragment(near_vector)
    row = ContentEmbedding.find_by(embeddable: fragment)

    expect(row.embedding_dims).to eq(3072)
    expect(row.embedding.to_a.length).to eq(3072)
  end

  it 'returns the closer fragment first, with distances that separate the two' do
    near = sidecar_fragment(near_vector)
    far = sidecar_fragment(far_vector)

    hits = Embeddings::NearestNeighbors.call(
      embeddable_type: 'Fragment', organisation: organisation,
      query_vector: query_vector, limit: 10
    )

    expect(hits.map(&:record)).to eq([near, far])
    # Not just "sorted": the values must be genuinely different, otherwise the ordering
    # rests on tie-breaking rather than on distance.
    expect(hits.first.distance).to be < hits.last.distance
    expect(hits.last.distance - hits.first.distance).to be > 0.1
  end

  # The triple filter is what keeps spaces apart. A row sitting in the 1536 space must
  # stay invisible to a 3072 reader even though it belongs to the same org and type —
  # this is the mechanism that turned yesterday's production model mix-up from "silently
  # wrong results" into "visibly empty", and it must hold for the halfvec lane too.
  it 'ignores a fragment whose sidecar row lives in a different vector space' do
    near = sidecar_fragment(near_vector)
    sidecar_fragment(Array.new(1536, 0.5), space_dims: 1536)

    hits = Embeddings::NearestNeighbors.call(
      embeddable_type: 'Fragment', organisation: organisation,
      query_vector: query_vector, limit: 10
    )

    expect(hits.map(&:record)).to eq([near])
  end
end
