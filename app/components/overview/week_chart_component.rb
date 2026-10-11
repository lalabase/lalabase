# frozen_string_literal: true

# Overview widget: bar chart of the viewer's tracked hours across the selected
# period (this week / month / quarter / last 10 days). Thin wrapper around the
# shared Dashboard::DailyBriefing#period_hours; its buckets array is daily for the
# short periods and monthly for the quarter. Period switching + drill-down live in
# Overview::PeriodWidget. Same permission gate as WeekStats (time_sessions:read in
# any project).
class Overview::WeekChartComponent < ViewComponent::Base
  include Overview::PeriodWidget # period/frame/drill-down + Turbo::FramesHelper

  WIDGET_KEY = 'my_week_chart'

  # Up to this many buckets, every bucket gets an x-axis label (a week = 7, last
  # 10 days = 10 all fit). Above it, labels would collide in the narrow widget.
  MAX_LABELS_WITHOUT_THINNING = 11
  # When thinning, aim for roughly this many evenly spaced labels across the axis.
  TARGET_THINNED_LABEL_COUNT = 7

  private

  def buckets
    data[:buckets]
  end

  # Bar height as a percentage of the busiest bucket, with a small floor so empty
  # buckets still show a sliver. max is clamped to >= 1 to avoid divide-by-zero.
  def bar_height_percent(hours)
    [(hours / [max_hours, 1].max.to_f * 100).to_i, 4].max
  end

  # The busiest bucket's hours — what the tallest bar represents. Surfaced as the chart's scale
  # reference so a single high day no longer reads as an unlabelled spike "through the roof".
  def max_hours
    buckets.map { |bucket| bucket[:hours] }.max || 0
  end

  # Whether the bucket at `index` shows its x-axis label. Few buckets (week, 10
  # days) -> label them all. Many buckets (a 31-day month) -> keep only a thinned,
  # evenly spaced subset so labels don't overlap, but ALWAYS keep the first, last
  # and current bucket so the axis stays readable and oriented on "today".
  def show_label?(index)
    return true if buckets.size <= MAX_LABELS_WITHOUT_THINNING

    first_or_last = index.zero? || index == buckets.size - 1
    evenly_spaced = (index % label_step).zero?

    first_or_last || buckets[index][:current] || evenly_spaced
  end

  # Show every Nth label, chosen so ~TARGET_THINNED_LABEL_COUNT remain.
  def label_step
    (buckets.size.to_f / TARGET_THINNED_LABEL_COUNT).ceil
  end
end
