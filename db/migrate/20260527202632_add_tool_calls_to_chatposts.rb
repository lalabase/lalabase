# frozen_string_literal: true

# Adds an audit trail of LLM tool-calls executed for an assistant response.
# Defaults to empty array so legacy rows and rows from text-only responses
# stay valid without explicit assignment.
class AddToolCallsToChatposts < ActiveRecord::Migration[8.0]
  def change
    add_column :chatposts, :tool_calls, :jsonb, default: [], null: false
  end
end
