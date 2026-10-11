# frozen_string_literal: true

# Gespräche Slice 6: the embedding-pipeline status columns that
# EmbeddingProcessingService writes to (plan §5). Deliberately nullable with NO
# default, exactly like notes/document_versions — nil means "never attempted",
# false means "attempted and failed" (embedding_creation_error carries the why),
# true means "embedded". create_embeddings + plain_text_version already exist
# since Slice 1a, so they are NOT re-added here.
#
# Column names are asymmetric on purpose (flag is plural, error is singular),
# matching the existing Note/DocumentVersion columns so the generic service works
# unchanged — do NOT "harmonise" them.
class AddEmbeddingPipelineColumnsToMeetings < ActiveRecord::Migration[8.0]
  def change
    add_column :meetings, :embeddings_creation_flag, :boolean
    add_column :meetings, :embedding_creation_error, :text
  end
end
