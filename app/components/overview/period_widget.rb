# frozen_string_literal: true

module Overview
  # Shared behaviour for the personal week widgets (my_week_stats / my_week_chart):
  # the selectable reporting period, its memoised aggregates from the briefing, the
  # Turbo frame id used for the in-place period switch, and the drill-down into
  # "Zeiten". The including component MUST define a WIDGET_KEY constant.
  #
  # Lives as a concern (not a base class) because the two widgets are otherwise
  # unrelated ViewComponents with different templates — they share behaviour, not a
  # type. Keeping it here means the period/frame/drill-down logic has exactly one
  # definition instead of being copy-pasted into both components.
  module PeriodWidget
    # `turbo_frame_tag` is a Rails view helper and is NOT auto-mixed into
    # ViewComponent, so each including widget needs it for the template wrapper.
    # Done here (once) rather than in every widget so nobody can forget it.
    def self.included(base)
      base.include(Turbo::FramesHelper)
    end

    def initialize(organisation:, user:, briefing:, period: nil)
      @organisation = organisation
      @user = user
      @briefing = briefing
      # Explicit period (from the refresh endpoint) wins; otherwise the per-user
      # stored choice. Both are normalised against the whitelist so a stale or
      # hand-edited preference can never reach the query layer.
      @period = period ? Overview::TimePeriod.normalize(period) : user.overview_widget_period(widget_key)
    end

    # Same gate for both widgets: time-tracking read access in ANY project.
    def should_render?
      Current.area_access_anywhere?(user, organisation, :time_sessions, :read)
    end

    private

    attr_reader :organisation, :user, :briefing, :period

    def widget_key
      self.class::WIDGET_KEY
    end

    # One Turbo frame per widget key. NOTE: this assumes a single instance of each
    # week widget on the overview (the realistic case). Two instances of the same
    # widget would share a frame id and refresh together — revisit with a per-slot
    # suffix if the layout ever needs duplicates.
    def frame_id
      "overview_widget_#{widget_key}"
    end

    def data
      @data ||= briefing.period_hours(period)
    end

    # Drill-down into "Zeiten": SAME period, only my sessions, sum shown, and
    # ALL billing states (so the listed total matches the headline "tracked" figure,
    # which also counts every state). The shared TimePeriod date_range guarantees the
    # drill-down window is identical to the widget's.
    def drilldown_path
      helpers.organisation_time_sessions_path(
        organisation,
        date_range: period,
        creator_id: user.id,
        status_filters: TimeSession::BILLING_STATUS_FILTERS
      )
    end
  end
end
