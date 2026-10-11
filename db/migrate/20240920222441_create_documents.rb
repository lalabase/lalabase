class CreateDocuments < ActiveRecord::Migration[7.2]
  def change
    create_table :documents, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: true
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.timestamps
    end
  end
end
