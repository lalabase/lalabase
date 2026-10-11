# frozen_string_literal: true

# Which of a view's columns stay readable when the width runs out
# (doc/spaltenwahl_plan.md; designer "Spaltenpanel: Anpinnen einbauen", § 2).
#
# A list of keys beside the ordered list, not a flag inside it: the order is
# what the reader drags, and a pin is a different question about the same
# column. Keys that are no longer chosen stay in the list on purpose - unticking
# a column and ticking it again should not lose the pin.
#
# jsonb with a default, so no table rewrite: Postgres stores the default in the
# catalogue and fills it in on read.
class AddPinnedColumnsToViewConfigurations < ActiveRecord::Migration[8.0]
  def change
    add_column :view_configurations, :pinned_columns, :jsonb, default: []
  end
end
