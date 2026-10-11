# frozen_string_literal: true

# D9 (MCP server): durable idempotency for the write tools. A client may send an
# optional idempotency_key; the first successful write stores its response here,
# and a repeat with the same (token, key) replays that response instead of writing
# again. Scoped per PAT so keys cannot collide or leak across tokens.
class CreateMcpIdempotencyKeys < ActiveRecord::Migration[8.0]
  def change
    create_table :mcp_idempotency_keys, id: :uuid do |t|
      # No own index: the unique (token, key) composite below already covers
      # lookups by token via its leftmost column.
      t.references :personal_access_token, type: :uuid, null: false, foreign_key: true, index: false
      t.string :idempotency_key, null: false
      t.string :tool_name, null: false
      t.string :request_fingerprint, null: false
      t.text :response_content
      t.timestamps
    end

    add_index :mcp_idempotency_keys, %i[personal_access_token_id idempotency_key],
              unique: true, name: 'index_mcp_idempotency_keys_on_token_and_key'
  end
end
