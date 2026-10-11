# frozen_string_literal: true

# Marker for system-created projects (currently only the onboarding tutorial
# project, value 'onboarding'). A stable identity independent of the project
# name — the name is user-editable and locale-dependent, so it cannot serve as
# the lookup key for the onboarding banner, the seed idempotency guard or the
# backfill skip logic. See doc/onboarding_plan.md (decision D5).
class AddSystemKindToProjects < ActiveRecord::Migration[8.0]
  def change
    add_column :projects, :system_kind, :string

    # Partial UNIQUE index: only system projects carry a value, regular
    # projects stay out of the index entirely. Lookup pattern is always
    # org-scoped ("the onboarding project of this organisation"). Unique on
    # purpose: an organisation may have AT MOST ONE project per system_kind —
    # the seed actor's find_by guard has a race window (double submit), the
    # index closes it at the DB layer. The losing racer's seed transaction
    # rolls back; the registration itself survives (controller isolation).
    add_index :projects, %i[organisation_id system_kind],
              where: 'system_kind IS NOT NULL',
              unique: true,
              name: 'idx_projects_on_org_and_system_kind'
  end
end
