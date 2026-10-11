# frozen_string_literal: true

# Every version of a document gets a number, v1, v2, ..., the identifier one
# talks about (doc/dokumentansicht_plan.md, S1): the file name repeats, the time
# is not a name. Nullable here, because the stock is numbered by a task
# (documents:number_versions), never by a schema migration; the NOT NULL comes
# in a second migration once that task has run in production. The unique index
# can come now: Postgres treats NULLs as distinct, so unnumbered rows do not
# collide, and two versions of one document can never share a number.
class AddNumberToDocumentVersions < ActiveRecord::Migration[8.0]
  def change
    add_column :document_versions, :number, :integer
    add_index :document_versions, %i[document_id number], unique: true
  end
end
