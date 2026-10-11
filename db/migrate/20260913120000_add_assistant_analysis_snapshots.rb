class AddAssistantAnalysisSnapshots < ActiveRecord::Migration[8.0]
  def change
    add_column :chatposts, :analysis_context, :jsonb
    add_column :meeting_analyses, :source_context, :jsonb
    add_column :meeting_analyses, :source_answer_key, :string
    add_index :meeting_analyses, :source_answer_key, unique: true
  end
end
