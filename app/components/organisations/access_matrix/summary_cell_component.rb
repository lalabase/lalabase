# frozen_string_literal: true

# One cell of the org access matrix: a member's condensed, effective access to a project.
# Read-only counterpart to Team::AccessCellComponent — it renders its OWN light markup via
# the shared Organisations::AccessLevelStyles module. It deliberately does NOT compose an
# AccessCellComponent per cell (that would explode into U×P components — Codex C4).
#
# Three visual states:
#   access  -> level pill (amber read_only / emerald read_write) + a lock when inherited
#              (source admin/role); a <details> popover lists the per-area breakdown
#   blocked -> red "Gesperrt" pill (an explicit no_access that overrides a role right)
#   none    -> neutral cream dash ("Kein Zugriff") — benign, never an error look
#
# The per-area breakdown lives in a keyboard-reachable <details> popover (a11y), NOT a
# hover-only title (Codex C7). Level/state is always icon + label, never colour alone.
class Organisations::AccessMatrix::SummaryCellComponent < ViewComponent::Base
  include Organisations::AccessLevelStyles

  def initialize(cell:, areas: ProjectPermission.access_areas)
    @cell = cell
    @areas = areas
  end

  private

  attr_reader :cell, :areas

  # The AccessLevelStyles helpers (icon/pill_class/level_label) default their argument to
  # this; for an access cell it is read_only/read_write.
  def level
    cell.level
  end

  def area_label(area)
    t("views.organisations.project_permissions.areas.#{area}")
  end
end
