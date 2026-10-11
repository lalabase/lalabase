# frozen_string_literal: true

# One area's access, rendered two ways from the same component:
#   mode: :view  -> a single effective pill (icon + label + colour). `no_access` is
#                   neutral grey, NOT red — a benign state must not read as an error.
#   mode: :edit  -> a 3-way segmented radio control (no_access / read_only / read_write).
#
# Shared level styling (LEVELS/ICONS/PILL_CLASSES + icon/pill_class/level_label) lives in
# Organisations::AccessLevelStyles so the read-only org access matrix renders identical
# pills. Edit-mode-only styling stays here.
#
# Accessibility: level is encoded by icon + text, never colour alone; the segmented
# control is a native same-name radio group (arrow-key nav for free) with an aria-label,
# and touch targets are >= 44px on mobile.
class Organisations::Team::AccessCellComponent < ViewComponent::Base
  include Organisations::AccessLevelStyles

  CHECKED_CLASSES = {
    'no_access' => 'peer-checked:bg-cream-200 peer-checked:text-ink',
    'read_only' => 'peer-checked:bg-amber-300 peer-checked:text-amber-900',
    'read_write' => 'peer-checked:bg-emerald-300 peer-checked:text-emerald-900'
  }.freeze

  def initialize(area:, level:, inherited: false, mode: :view, user_id: nil)
    @area = area.to_s
    @level = level.to_s
    @inherited = inherited
    @mode = mode.to_sym
    @user_id = user_id
  end

  private

  attr_reader :area, :level, :inherited, :mode, :user_id

  def checked_class(lvl)
    CHECKED_CLASSES.fetch(lvl, '')
  end

  def field_name
    "project_permission[#{area}_access]"
  end

  def input_id(lvl)
    "perm_#{user_id}_#{area}_#{lvl}"
  end
end
