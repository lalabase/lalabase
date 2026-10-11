# frozen_string_literal: true

# D3 (MCP server): a PAT is read-only by default. The MCP write tools
# (create_ticket, post_comment) refuse to run for a read-only token — granting
# write is an explicit opt-in. Default true is least-privilege; existing tokens
# become read-only and must be flipped to gain MCP write access. The HTTP API is
# intentionally NOT gated on this flag (its write behaviour is unchanged).
class AddReadOnlyToPersonalAccessTokens < ActiveRecord::Migration[8.0]
  def change
    add_column :personal_access_tokens, :read_only, :boolean, default: true, null: false
  end
end
