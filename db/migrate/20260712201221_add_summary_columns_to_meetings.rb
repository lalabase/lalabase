class AddSummaryColumnsToMeetings < ActiveRecord::Migration[8.0]
  # Gespräche Slice 4: one AI summary per meeting, generated async. Exactly the
  # DocumentVersion column trio (generated_summary / summary_creation_flag /
  # summary_creation_error) so the display + status pattern is reused. Non-null
  # string defaults keep view code free of nil checks; the flag defaults false.
  def change
    add_column :meetings, :generated_summary, :text, default: '', null: false
    add_column :meetings, :summary_creation_flag, :boolean, default: false, null: false
    add_column :meetings, :summary_creation_error, :text, default: '', null: false
  end
end
