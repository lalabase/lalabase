# frozen_string_literal: true

# A note is indexed like a ticket (doc/notizen_immer_indexiert_plan.md): the
# column stays (EmbeddingProcessingService reads it, meetings keep their
# deliberate opt-in), only its default turns. Existing rows are flipped by the
# task notes:index_everything, not here (data migrations are tasks).
class NotesAreIndexedByDefault < ActiveRecord::Migration[8.0]
  def change
    change_column_default :notes, :create_embeddings, from: false, to: true
  end
end
