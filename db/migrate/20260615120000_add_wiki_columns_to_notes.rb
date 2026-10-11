# frozen_string_literal: true

# Wiki build-out, phase 0b/1:
#   markdown_body  — derived GFM projection (the ActionText content stays the source
#                    of truth). Bridge for diff / import / MCP. Nullable, filled by the
#                    backfill for existing rows.
#   lock_version   — optimistic locking against lost updates from parallel tabs /
#                    MCP writes. Rails uses this column automatically.
class AddWikiColumnsToNotes < ActiveRecord::Migration[8.0]
  def change
    add_column :notes, :markdown_body, :text
    add_column :notes, :lock_version, :integer, null: false, default: 0
  end
end
