# frozen_string_literal: true

# Shared visual vocabulary for a single access level (no_access / read_only / read_write):
# the pill colour classes, the Bootstrap icon, and the translated label. Extracted so the
# editable Team cell (Organisations::Team::AccessCellComponent) and the read-only org matrix
# cell (Organisations::AccessMatrix::SummaryCellComponent) render identical level styling
# from ONE source — no drift between the two surfaces.
#
# Neutral namespace on purpose (NOT under Team::): it is owned by neither consumer.
#
# Mix into a ViewComponent with `include Organisations::AccessLevelStyles`. The host must
# expose a private `level` reader (the helpers default their argument to it), and `t`
# resolves on the component instance. Edit-mode-only styling (CHECKED_CLASSES, field_name,
# input_id) intentionally stays on AccessCellComponent — it is not shared.
module Organisations
  module AccessLevelStyles
    LEVELS = %w[no_access read_only read_write].freeze

    ICONS = {
      'no_access' => 'dash-lg',
      'read_only' => 'eye',
      'read_write' => 'pencil'
    }.freeze

    PILL_CLASSES = {
      'no_access' => 'bg-cream-100 text-cream-500 border-cream-300',
      'read_only' => 'bg-amber-100 text-amber-800 border-amber-300',
      'read_write' => 'bg-emerald-100 text-emerald-800 border-emerald-300'
    }.freeze

    private

    def icon(lvl = level)
      ICONS.fetch(lvl, 'dash-lg')
    end

    def pill_class(lvl = level)
      PILL_CLASSES.fetch(lvl, PILL_CLASSES['no_access'])
    end

    def level_label(lvl = level)
      t("views.organisations.project_permissions.levels.#{lvl}")
    end
  end
end
