# frozen_string_literal: true

# Shared period logic for dashboard components.
# Provides PERIOD_OPTIONS, period_range, and apply_period.
module DashboardPeriodable
  extend ActiveSupport::Concern

  PERIOD_OPTIONS = [
    ['all_time',     'dashboard.stat_cards.periods.all_time'].freeze,
    ['today',        'dashboard.stat_cards.periods.today'].freeze,
    ['this_week',    'dashboard.stat_cards.periods.this_week'].freeze,
    ['this_month',   'dashboard.stat_cards.periods.this_month'].freeze,
    ['last_30_days', 'dashboard.stat_cards.periods.last_30_days'].freeze,
    ['this_quarter', 'dashboard.stat_cards.periods.this_quarter'].freeze
  ].freeze

  VALID_PERIODS = PERIOD_OPTIONS.map(&:first).to_set.freeze

  def period_range(period)
    case period
    when 'all_time'      then nil
    when 'today'         then Date.current.beginning_of_day..
    when 'this_week'     then Date.current.beginning_of_week..
    when 'this_month'    then Date.current.beginning_of_month..
    when 'last_30_days'  then 30.days.ago..
    when 'this_quarter'  then Date.current.beginning_of_quarter..
    else
      Rails.logger.warn("[DashboardPeriodable] Unknown period: #{period.inspect}, defaulting to all_time")
      nil
    end
  end

  def apply_period(scope, period, column: :created_at)
    range = period_range(period)
    range ? scope.where(column => range) : scope
  end
end
