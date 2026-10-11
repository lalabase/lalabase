class AddLanguagePreferenceToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :language_preference, :string, default: 'de', null: false
    add_index :users, :language_preference
  end
end
