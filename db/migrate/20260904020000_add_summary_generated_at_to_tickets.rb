# frozen_string_literal: true

# The summary block on the ticket timeline shows WHEN the summary was created
# (design mock 04.09.2026). Nullable on purpose: summaries that already exist
# have no known date and render without one - no backfill, no guessing.
class AddSummaryGeneratedAtToTickets < ActiveRecord::Migration[8.0]
  def change
    add_column :tickets, :summary_generated_at, :datetime
  end
end
