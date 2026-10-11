# frozen_string_literal: true

# S2: cost_cents was INTEGER, so a cheap model (~0.002 cents/call) rounded to 0 and
# the usage statistics under-counted almost everything. Widen to decimal(12,6) —
# pure STATISTIC precision, no behaviour change: existing integer values convert
# losslessly (45 -> 45.000000) and every display path divides by 100.0, which works
# on a BigDecimal just as on an Integer. The `.round` in the tracking path is
# removed alongside this (see Lalabase::Llm::UsageTracking).
class ChangeAiUsagesCostCentsToDecimal < ActiveRecord::Migration[8.0]
  def up
    change_column :ai_usages, :cost_cents, :decimal, precision: 12, scale: 6, default: 0
  end

  def down
    change_column :ai_usages, :cost_cents, :integer, default: 0
  end
end
