class AddIndexToActionTextRichTexts < ActiveRecord::Migration[8.0]
  def change
    # Add index for faster content searches in ActionText
    # This helps when SmartFolders search in ticket/note content
    add_index :action_text_rich_texts, [:record_type, :record_id, :name], 
              name: 'index_action_text_on_record_and_name',
              if_not_exists: true
  end
end
