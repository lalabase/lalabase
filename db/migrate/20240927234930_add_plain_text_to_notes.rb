class AddPlainTextToNotes < ActiveRecord::Migration[7.2]
  def change
    add_column :notes, :plain_text_version, :text
    add_column :notes, :plain_text_word_count, :integer
  end
end
