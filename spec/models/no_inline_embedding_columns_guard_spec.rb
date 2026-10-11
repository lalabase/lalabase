# frozen_string_literal: true

require 'rails_helper'

# Schema guard: the inline embedding lane stays gone (embedding v2 PR 7).
#
# Until PR 7 vectors lived twice — in four inline columns and in the
# content_embeddings sidecar. The sidecar has been the only READ source since PR 4b
# and is now the only source at all. This spec is the successor of
# embedding_column_defaults_spec, which pinned the DEFAULTS of those very columns:
# same role, opposite assertion.
#
# Why a guard for something a migration already did: db/schema.rb is written by
# whichever database the last `db:migrate` ran against, and this project shares one
# development database across ~16 worktrees. A branch that migrates against a
# database still carrying these columns dumps them straight back into schema.rb, and
# a later db:schema:load resurrects them — silently, because nothing reads them and
# nothing would fail. The columns would simply be back, and the doubled storage with
# them.
#
# Deliberately asserted against the LOADED SCHEMA (column_names), not against
# schema.rb as text: the question is what the database a spec run sees actually has.
RSpec.describe 'inline embedding lane' do
  # The four tables that carried a vector, and the column name each used. A plain
  # constant would be a Lint/ConstantDefinitionInBlock offence, and the iteration
  # below needs the value at EXAMPLE-GROUP build time, so `let` is not an option
  # for the outer loop either — hence a method.
  def self.inline_vector_columns
    { 'CodeSymbol' => 'signature_embedding',
      'Fragment' => 'embedding',
      'ProjectCapability' => 'description_embedding',
      'ProjectLayer4Vision' => 'content_embedding' }
  end

  # The provenance PAIR sat on all four alike. It said which vector space the inline
  # vector belonged to — a statement the sidecar row now makes, with the dimension
  # included (the pair could not express a dims-only switch; see the reindexer).
  let(:provenance_columns) { %w[embedding_provider embedding_model] }

  inline_vector_columns.each do |model_name, vector_column|
    describe model_name do
      let(:model) { model_name.constantize }

      it "no longer has the inline vector column #{vector_column}" do
        expect(model.column_names).not_to include(vector_column)
      end

      it 'no longer has the inline provenance pair' do
        expect(model.column_names).not_to include(*provenance_columns)
      end
    end
  end

  # The two ANN indexes died with their columns. Asserted separately because an index
  # is what made the inline lane expensive rather than merely redundant — and because
  # a hand-written CREATE INDEX could bring one back without the column ever returning
  # (it could not, in fact, but the assertion costs one query and says so out loud).
  it 'has neither of the two inline ANN indexes' do
    index_names = ActiveRecord::Base.connection
                                    .select_values("SELECT indexname FROM pg_indexes WHERE schemaname = 'public'")

    expect(index_names).not_to include('idx_code_symbols_signature_embedding_hnsw')
    expect(index_names).not_to include('index_fragments_on_embedding')
  end

  # The counterpart: the sidecar is untouched by all of the above. Without this the
  # spec above would still pass on a database that lost the vectors entirely.
  it 'still has the sidecar column the vectors moved into' do
    expect(ContentEmbedding.column_names).to include('embedding', 'embedding_dims')
  end
end
