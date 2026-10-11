# frozen_string_literal: true

class AddRagFieldsToChatposts < ActiveRecord::Migration[8.0]
  def change
    change_table :chatposts, bulk: true do |t|
      t.jsonb :source_citations, null: false, default: []
      t.string :model_used
      t.jsonb :token_usage, null: false, default: {}
    end
  end
end
