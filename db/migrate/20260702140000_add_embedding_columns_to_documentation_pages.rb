# frozen_string_literal: true

# Slice 3 (chat grounding): a DocumentationPage becomes an embeddable fragmentable
# type. The SHARED EmbeddingProcessingService sets embeddings_creation_flag on
# success (and raises without it), and EmbeddingReprocessingService backfills rows
# where the flag is NULL/false — so a page needs the SAME two bookkeeping columns
# Note/Post/Ticket/DocumentVersion already carry.
#
# No create_embeddings column ON PURPOSE: every synced doc page is grounding
# material (like Ticket, which also embeds unconditionally) — there is no per-page
# opt-out in the one-way repo-sync model. Both columns are nullable with no default:
# a fresh page is "pending" (flag NULL) until the embedding job flips it to true.
class AddEmbeddingColumnsToDocumentationPages < ActiveRecord::Migration[8.0]
  def change
    add_column :documentation_pages, :embeddings_creation_flag, :boolean
    add_column :documentation_pages, :embedding_creation_error, :text
  end
end
