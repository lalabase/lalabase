# frozen_string_literal: true

# Linear-style ascending signal bars for a priority level. Readable by FILL (form) first —
# `level` of `total` bars are filled — so the level is legible WITHOUT relying on color
# discrimination. Color is only an accent on the filled bars. Rendered as inline SVG with
# `fill` presentation attributes (no inline <style>, no stylesheet needed; the configured
# option color is an arbitrary hex with no Tailwind equivalent).
#
#   ▁▃▅▇  level 4/4 (urgent)      ▁▃▅_  level 3/4 (high)      ▁___  level 1/4 (low)
class NeoPriorityBarsComponent < ViewComponent::Base
  # More than four levels collapse into four bars (Linear caps visual density similarly).
  BAR_COUNT_CAP = 4

  BAR_WIDTH = 3
  BAR_GAP = 1
  MAX_HEIGHT = 13
  CHART_HEIGHT = 14

  FILLED_FALLBACK_COLOR = '#6b7280' # gray-500, when no option color is configured
  EMPTY_COLOR = '#d1d5db'           # gray-300, unfilled bars

  def initialize(level:, total:, color: nil, label: nil)
    super()
    @level = level.to_i
    @total = [total.to_i, 1].max
    @color = color.presence
    @label = label.presence
  end

  # Nothing to draw for an unset / zero level.
  def render?
    @level.positive?
  end

  def call
    tag.svg(
      width: chart_width, height: CHART_HEIGHT, viewBox: "0 0 #{chart_width} #{CHART_HEIGHT}",
      class: 'neo-priority-bars align-middle', role: 'img', 'aria-label': @label, fill: 'none',
      xmlns: 'http://www.w3.org/2000/svg'
    ) do
      safe_join([title_tag, *bar_tags].compact)
    end
  end

  private

  def bar_count
    [@total, BAR_COUNT_CAP].min
  end

  # How many of the (capped) bars are filled. With <= 4 levels the level IS the fill. With more
  # levels we scale into 4 bars and round UP (ceil), not down: a ticket that carries ANY priority
  # should never show fewer bars than a lower-priority one, and the top level must always fill all 4
  # bars (ceil guarantees level==total → 4). clamp(1, ...) ensures a set level never renders 0 bars.
  def filled_count
    raw = @total <= BAR_COUNT_CAP ? @level : ((@level.to_f / @total) * BAR_COUNT_CAP).ceil
    raw.clamp(1, bar_count)
  end

  def chart_width
    (bar_count * (BAR_WIDTH + BAR_GAP)) - BAR_GAP
  end

  def title_tag
    return unless @label

    tag.title(@label)
  end

  def bar_tags
    (0...bar_count).map do |i|
      height = 4 + (i * 3)
      filled = i < filled_count
      tag.rect(
        x: i * (BAR_WIDTH + BAR_GAP), y: MAX_HEIGHT - height + 1,
        width: BAR_WIDTH, height: height, rx: 0.5,
        fill: filled ? (@color || FILLED_FALLBACK_COLOR) : EMPTY_COLOR
      )
    end
  end
end
