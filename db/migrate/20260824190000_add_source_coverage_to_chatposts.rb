# frozen_string_literal: true

# S3a T3 (L7): an org-wide answer records how far its tools actually reached,
# as {searched:, total:} projects. The narrowing notice under the bubble is
# rendered deterministically from this field — never from the model's prose.
# Nullable without default: nil means "not applicable" (single-project answer),
# which is distinct from a recorded full reach.
class AddSourceCoverageToChatposts < ActiveRecord::Migration[8.0]
  def change
    add_column :chatposts, :source_coverage, :jsonb
  end
end
