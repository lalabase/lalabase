# frozen_string_literal: true

# The share bar of the Projektzeiten table: how much of a row's booked time is
# invoiced, queued for billing, or still loose.
#
# ONE owner of the three time-* colour tokens. Read by the table row, by the
# single booking under an opened row and by the mobile card, so a bar means the
# same thing wherever it is drawn (plan §4, decision of 30.08.2026).
#
# The bar carries no number of its own on purpose: the minutes live in its
# aria-label and title, which is where a screen reader and a hovering mouse both
# get them. What the eye reads off the bar is the proportion.
class NeoTimeShareBarComponent < ViewComponent::Base
  # Row bar and the thinner one under an opened row.
  #
  # 24px, not 40: beside it stands the other form of the same mark, and two dots
  # measure 14px (10 + 10 - 6 of overlap). At 40 the bar was nearly three times
  # the cluster and read as a different kind of thing rather than the same thing
  # divided. 24 keeps it clearly a bar while staying in the same family.
  SIZES = {
    row: 'h-2 w-6',
    thin: 'h-[5px] w-5'
  }.freeze

  # A row in ONE state has nothing to divide, and a bar that shows no division
  # still claims one. It gets a dot instead: same colour, same meaning, no false
  # promise of a proportion. The bar is then rare, and where it appears it says
  # something (decision of 30.08.2026).
  DOT_SIZES = {
    row: 'h-2.5 w-2.5',
    thin: 'h-2 w-2'
  }.freeze

  # A dot is filled even where a bar segment is not. The bar's untouched part
  # shows the track through it, but a stack of dots needs opacity: only an opaque
  # circle can cover the one behind it, and covering is the whole difference
  # between "behind each other" and a pair of interlocking rings.
  DOT_FILLS = {
    'billed' => 'bg-time-billed',
    'in_billing' => 'bg-time-in-billing',
    'without_billing' => 'bg-surface'
  }.freeze

  # Drawn in this order, left to right: what is done, what is on its way, what is
  # untouched. The keys are the model's buckets (TimeSession::BILLING_STATUS_FILTERS),
  # never a fourth vocabulary.
  #
  # The untouched part is NOT painted. It keeps its width so the filled parts sit
  # where they belong, but the outlined track shows through it. That is what
  # makes the three steps readable: nothing, then grey, then ink.
  SEGMENTS = {
    'billed' => 'bg-time-billed',
    'in_billing' => 'bg-time-in-billing',
    'without_billing' => 'bg-transparent'
  }.freeze

  # shares: minutes per bucket, e.g. { 'billed' => 220, 'in_billing' => 60, 'without_billing' => 0 }
  def initialize(shares:, size: :row)
    super()
    @shares = shares || {}
    @size = SIZES.key?(size) ? size : :row
  end

  # Built here rather than as a condition inside the tag: an ERB branch between
  # attributes is unreadable and the ERB linter cannot parse it either.
  def track_attributes
    classes = if dot?
                'inline-flex items-center'
              else
                # rounded-sm, not rounded-full: a 24x8 pill with a lighter half
                # is the shape of a toggle switch, and this thing switches
                # nothing. A bar with square ends reads as a measure.
                "inline-flex overflow-hidden rounded-sm border border-stroke/70 #{SIZES.fetch(@size)}"
              end
    return { class: classes, 'aria-hidden' => 'true' } unless described?

    { class: classes, role: 'img', 'aria-label' => label, title: label }
  end

  # One filled bucket means one state, whether that is one booking or thirty.
  def dot?
    !single_bucket.nil?
  end

  # The mark says ONE thing: which state. It used to stack a second dot for a row
  # with several bookings, so it carried the state, the count and (through dot
  # versus bar) the uniformity all at once -- three dimensions in 24 pixels, with
  # no legend anywhere. The count is what the row's chevron is for.
  def dot_classes
    return nil unless dot?

    # 70%, not 40%: at 40 the outline of an EMPTY mark measured under 3:1 in all
    # three themes, and the outline is the whole mark when nothing is filled.
    "shrink-0 rounded-full border border-stroke/70 #{DOT_SIZES.fetch(@size)} #{DOT_FILLS.fetch(single_bucket)}"
  end

  # Percentages that always add up to 100: the last drawn segment takes the
  # remainder, so rounding never leaves a sliver of track between two shares.
  def segments
    return [] if total.zero? || dot?

    drawn = SEGMENTS.filter_map do |bucket, css_class|
      minutes = minutes_in(bucket)
      next if minutes.zero?

      { css_class: css_class, percent: ((minutes.to_f / total) * 100).round }
    end
    return drawn if drawn.empty?

    drawn[-1] = drawn.last.merge(percent: 100 - drawn[0..-2].sum { |segment| segment[:percent] })
    drawn
  end

  # Only the filled buckets, in the drawing order: "abgerechnet: 03:40 · in Abrechnung: 01:00".
  # The words come from the one owner (S1); this file used to carry a short copy
  # of them under keys of its own (status_short_grouped / status_short_open).
  def label
    SEGMENTS.keys.filter_map do |bucket|
      minutes = minutes_in(bucket)
      next if minutes.zero?

      "#{helpers.time_billing_state_label(bucket)}: #{TimeSession.format_duration(minutes)}"
    end.join(' · ')
  end

  # An empty bar says nothing, so it is decoration rather than an image with no
  # description. role="img" with an empty label is worse than no role at all.
  def described?
    total.positive?
  end

  private

  # The only bucket holding anything, or nil when it is none or several.
  def single_bucket
    return @single_bucket if defined?(@single_bucket)

    filled = SEGMENTS.keys.select { |bucket| minutes_in(bucket).positive? }
    @single_bucket = filled.one? ? filled.first : nil
  end

  def minutes_in(bucket)
    @shares[bucket].to_i
  end

  def total
    @total ||= SEGMENTS.keys.sum { |bucket| minutes_in(bucket) }
  end
end
