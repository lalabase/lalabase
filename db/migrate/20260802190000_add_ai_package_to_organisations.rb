# frozen_string_literal: true

# KI-Pakete P2 (doc/ki_pakete_plan.md §6.1): the org's package choice. NULL
# behaves like kind 'custom' (E1-C) — existing orgs need no data migration and
# there is still exactly ONE resolution path in the factory.
#
# ai_package_tier_key addresses the performance rung by key (fast/thorough);
# P2 defaults new selections to 'fast', the customer-facing switch lands in P3.
#
# FK deliberately WITHOUT on_delete: deleting a package that organisations run
# on must fail at the database — a silent NULLify would drop those orgs back to
# their custom columns without anyone choosing that (the same last-line role
# the credential FKs play, plan §7b.2).
#
# selected_at/by: the switch protocol (§7 — "wer wann gewechselt hat"), the
# basis for "EU ist Standard, US die bewusste Abweichung".
class AddAiPackageToOrganisations < ActiveRecord::Migration[8.0]
  def change
    change_table :organisations, bulk: true do |t|
      t.uuid :ai_package_id
      t.string :ai_package_tier_key
      t.datetime :ai_package_selected_at
      t.uuid :ai_package_selected_by_id
    end

    add_foreign_key :organisations, :ai_packages
    add_foreign_key :organisations, :users, column: :ai_package_selected_by_id, on_delete: :nullify
    add_index :organisations, :ai_package_id
  end
end
