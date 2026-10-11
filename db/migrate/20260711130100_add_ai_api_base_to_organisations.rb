# frozen_string_literal: true

# S2: chat-side pendant to the existing embedding_api_base column. Lets a future
# BYOK org point its CHAT traffic at its own OpenAI-compatible endpoint, exactly as
# embedding_api_base already does for embeddings. Nullable, no default: nil = "use
# the system credential's api_base / plain OpenAI". No BYOK UI wires this in S2
# (that is S5); the column + Factory plumbing land now so the seam is complete.
class AddAiApiBaseToOrganisations < ActiveRecord::Migration[8.0]
  def change
    add_column :organisations, :ai_api_base, :string
  end
end
