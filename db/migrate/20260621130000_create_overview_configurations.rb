# frozen_string_literal: true

# Per-user / per-org-default layout config for the organisation overview
# (briefings#show), mirroring dashboard_configurations but scoped to the
# organisation itself (no project). Cascade: user config -> org default
# (user_id NULL) -> system default. See doc/overview_widgets_plan.md.
class CreateOverviewConfigurations < ActiveRecord::Migration[8.0]
  def change
    create_table :overview_configurations, id: :uuid do |t|
      t.references :organisation, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: true, foreign_key: true
      t.jsonb :layout, null: false, default: []
      t.timestamps
    end

    # Exactly one personal config per (user, organisation).
    add_index :overview_configurations, %i[user_id organisation_id],
              unique: true,
              name: 'idx_overview_config_user_org'

    # Exactly one org default per organisation (the user_id IS NULL row).
    add_index :overview_configurations, [:organisation_id],
              unique: true,
              where: 'user_id IS NULL',
              name: 'idx_overview_config_org_default'
  end
end
