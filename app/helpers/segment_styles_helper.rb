# frozen_string_literal: true

# Shared classes for connected single-select segments (stadium shape).
#
# Link-based segments (navigation via query param, NO radio inputs) use this
# helper so that the segment look has only ONE definition. The canonical
# (radio-based) reference is NeoSegmentedRadioComponent / /style-guide; the
# visual recipe here is DELIBERATELY kept identical to the component.
#
# Rule (see doc/style_guide_pass2_befunde.md, Theme B + design_system.md Part G):
# - Single-select  -> connected segment (stadium shape, active = ink/dark)
# - Multi-select   -> separate checkbox pills
#
# Usage (inside the container `inline-flex items-center rounded-full`):
#   <%= link_to label, url, class: segment_cell_classes(active?) %>
module SegmentStylesHelper
  # Core without corner/position logic (rounding is added per variant).
  SEGMENT_CELL_CORE = 'relative inline-flex items-center justify-center px-3 py-1 ' \
    'text-xs font-medium border border-cream-300 cursor-pointer transition-all duration-200'
  # Active = warm fill (cream-200) + thin ink border + bold (Part G/G4: NOT lime,
  # but NO dark block — too heavy as a permanent element). Clearly "on" via border+weight.
  SEGMENT_CELL_ACTIVE = 'bg-cream-200 text-cream-900 border-ink font-semibold z-[2]'
  SEGMENT_CELL_INACTIVE = 'bg-cream-50 text-cream-700 hover:bg-cream-100 hover:z-[1]'

  # Variant A — cells are direct DOM siblings (e.g. <a> links):
  # first:/last: pseudo rounds the outer ends, -ml-px collapses the borders.
  def segment_cell_classes(active)
    edges = '-ml-px first:ml-0 first:rounded-l-full first:pl-4 last:rounded-r-full last:pr-4'
    "#{SEGMENT_CELL_CORE} #{edges} #{active ? SEGMENT_CELL_ACTIVE : SEGMENT_CELL_INACTIVE}"
  end

  # Variant B — cells are NOT direct siblings (e.g. button_to forms with
  # display:contents): the first:/last: pseudo doesn't apply → specify the position
  # explicitly (:first | :middle | :last). The order must be statically known.
  def segment_cell_classes_at(active, position)
    edges = case position
            when :first then 'rounded-l-full pl-4'
            when :last  then '-ml-px rounded-r-full pr-4'
            else             '-ml-px'
            end
    "#{SEGMENT_CELL_CORE} #{edges} #{active ? SEGMENT_CELL_ACTIVE : SEGMENT_CELL_INACTIVE}"
  end
end
