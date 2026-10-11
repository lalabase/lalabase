# frozen_string_literal: true

class CreatePostReactionsAndReads < ActiveRecord::Migration[8.0]
  def change
    create_table :post_reactions, id: :uuid do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.references :post, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :emoji, null: false
      t.timestamps
    end
    add_index :post_reactions, %i[post_id user_id emoji], unique: true,
                                                          name: 'index_post_reactions_on_post_user_emoji'

    create_table :post_reads, id: :uuid do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.references :post, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :read_at, null: false
      t.timestamps
    end
    add_index :post_reads, %i[post_id user_id], unique: true,
                                                name: 'index_post_reads_on_post_user'
  end
end
