# frozen_string_literal: true

# Aggregates the "what's new since the daily cutoff" briefing for a user
# within an organisation. Cutoff is today at 06:00 local; if it's currently
# before 06:00, the cutoff is yesterday at 06:00 (so early-morning users still
# see the previous day's activity).
module Dashboard
  class DailyBriefing
    DAILY_CUTOFF_HOUR = 6
    MAX_ACTIVITY_ITEMS_PER_PROJECT = 5

    attr_reader :user, :organisation, :now

    def initialize(user:, organisation:, now: Time.current)
      @user = user
      @organisation = organisation
      @now = now
    end

    def cutoff_time
      @cutoff_time ||= begin
        base = now.change(hour: DAILY_CUTOFF_HOUR, min: 0, sec: 0)
        now.hour < DAILY_CUTOFF_HOUR ? base - 1.day : base
      end
    end

    def greeting_phrase
      if now.hour < 11 then I18n.t('dashboard.briefing.greeting.morning')
      elsif now.hour < 18 then I18n.t('dashboard.briefing.greeting.afternoon')
      else
        I18n.t('dashboard.briefing.greeting.evening')
      end
    end

    def project_ids
      @project_ids ||= permitted_projects.pluck(:id)
    end

    def permitted_projects
      @permitted_projects ||= ProjectPolicy::Scope.new(user, organisation.projects.active).resolve
    end

    # Activities grouped by project. Each entry is a Hash:
    #   { project:, items: [Activity, ...] }
    # Empty if there's nothing new.
    def new_activities_by_project
      return [] if project_ids.empty?

      activities = Activity
                   .where('activities.created_at >= ?', cutoff_time)
                   .where.not(actor_id: user.id) # only "what others did"
                   .joins("LEFT JOIN tickets ON activities.trackable_type = 'Ticket' AND tickets.id = activities.trackable_id")
                   .where('tickets.project_id IN (?) OR activities.trackable_type != ?', project_ids, 'Ticket')
                   .includes(:actor, :trackable)
                   .order(created_at: :desc)
                   .limit(100)

      grouped = activities.group_by { |a| project_for_activity(a) }.compact
      grouped
        .reject { |project, _| project.nil? || !project_ids.include?(project.id) }
        .sort_by { |_, items| -items.first.created_at.to_i }
        .map { |project, items| { project: project, items: items.first(MAX_ACTIVITY_ITEMS_PER_PROJECT) } }
    end

    def new_activities_count
      new_activities_by_project.sum { |group| group[:items].size }
    end

    # Hours tracked by current_user for the given reporting period (the canonical
    # set lives in Overview::TimePeriod). "unbilled" = sessions not yet billed
    # (billed=false). Memoised per period so a page with both week widgets on the
    # same period runs the aggregation once.
    #
    # @param period_key [String] one of Overview::TimePeriod::KEYS (unknown -> DEFAULT)
    # @return [Hash] period_key, title_key, subtitle, tracked, unbilled,
    #   buckets (Array<Hash{label:, hours:, current:}> for the chart)
    def period_hours(period_key = Overview::TimePeriod::DEFAULT)
      @period_hours ||= {}
      @period_hours[Overview::TimePeriod.normalize(period_key)] ||= compute_period_hours(period_key)
    end

    # Consistent with the inbox badge in the navigation (channel_in_app + access).
    def unread_notifications_count
      @unread_notifications_count ||= user.unread_notifications_count(organisation)
    end

    # Aggregated feed: one entry per (Trackable, Actor) with a headline action
    # and a secondary counter. Reduces noise from multiple edits of the same
    # ticket by the same person.
    #
    # Orthogonal to the notifications lane: Activities on Trackables for which
    # the user already has a notification are hidden. The lane thus shows only
    # "What is happening in your projects without the system having directly
    # informed you?" — no duplicate of the notifications lane.
    # @return [Array<BriefingActivityGroup>]
    def recent_activities_others(limit: 20)
      return [] if project_ids.empty?

      notified_trackables = user.notifications
                                .where(organisation: organisation)
                                .pluck(:notifiable_type, :notifiable_id)
                                .to_set

      raw = Activity
            .where.not(actor_id: user.id)
            .joins("LEFT JOIN tickets ON activities.trackable_type = 'Ticket' AND tickets.id = activities.trackable_id")
            .where('tickets.project_id IN (?) OR activities.trackable_type != ?', project_ids, 'Ticket')
            .includes(:actor, :trackable)
            .order(created_at: :desc)
            .limit(limit * 3) # load more so that enough groups remain after aggregation + notification filter
            .to_a
            .reject do |a|
        pid = project_id_for_activity(a)
        pid.nil? || !project_ids.include?(pid)
      end
            .reject { |a| notified_trackables.include?([a.trackable_type, a.trackable_id]) }

      BriefingActivityGroup.aggregate(raw).first(limit)
    end

    # @return [Array<Hash>] per project: { project:, unread_count:, in_billing_hours:,
    # without_billing_hours: }. Feeds the project table on the overview.
    #   - unread_count          : unread in-app notifications (like the inbox badge)
    #   - in_billing_hours       : hours in billing (billed=false, group set)
    #   - without_billing_hours  : hours not yet billed (billed=false, no group)
    # Sorting: projects with unread items first, then most open hours, then name.
    def projects_overview
      return [] if project_ids.empty?

      # The inbox rule (areas, active projects), so a project row never promises
      # unread items its inbox link cannot show.
      unread = Notification.inbox_unread(user, organisation)
                           .where(project_id: project_ids)
                           .group(:project_id)
                           .count

      sessions = TimeSessionPolicy::Scope.new(
        user, TimeSession.where(project_id: project_ids, organisation: organisation)
      ).resolve.where(billed: false)

      in_billing = sessions.where.not(time_session_group_id: nil).group(:project_id).sum(:duration)
      without_billing = sessions.where(time_session_group_id: nil).group(:project_id).sum(:duration)

      last_activity = TicketPolicy::Scope.new(user, Ticket.where(project_id: project_ids))
                                         .resolve.group(:project_id).maximum(:updated_at)

      permitted_projects.map do |project|
        {
          project: project,
          unread_count: unread[project.id] || 0,
          in_billing_hours: ((in_billing[project.id] || 0) / 60.0).round(1),
          without_billing_hours: ((without_billing[project.id] || 0) / 60.0).round(1),
          last_activity_at: last_activity[project.id]
        }
      end.sort_by do |e|
        [-e[:unread_count], -(e[:in_billing_hours] + e[:without_billing_hours]), e[:project].name.to_s.downcase]
      end
    end

    # Most recently touched project the user has access to. Used for the
    # "back to my last project" quick action.
    def last_active_project
      @last_active_project ||= permitted_projects
                               .joins(:tickets)
                               .where('tickets.updated_at >= ?', 30.days.ago)
                               .order('tickets.updated_at DESC')
                               .first
    end

    private

    def compute_period_hours(period_key)
      period = Overview::TimePeriod.range_for(period_key, now: now)
      sessions = TimeSession.where(creator: user, organisation: organisation)
                            .where(occurred_on: period.start_at..period.end_at)
      tracked_minutes  = sessions.sum(:duration)
      unbilled_minutes = sessions.where(billed: false).sum(:duration)

      {
        period_key: period.key,
        title_key: period.title_key,
        subtitle: period.subtitle,
        tracked: (tracked_minutes / 60.0).round(1),
        unbilled: (unbilled_minutes / 60.0).round(1),
        buckets: build_period_buckets(period, sessions)
      }
    end

    # Time-series buckets for the chart: monthly for the quarter (3 bars),
    # daily for the shorter periods. Each bucket: { label:, hours:, current: }.
    # Aggregated in Ruby from the already-scoped per-user/per-period set (bounded,
    # so no extra query), using occurred_on.to_date for zone-consistent bucketing.
    def build_period_buckets(period, sessions)
      by_day = sessions.group_by { |s| s.occurred_on.to_date }
                       .transform_values { |arr| arr.sum(&:duration) / 60.0 }
      today = now.to_date

      if period.key == 'this_quarter'
        first_month = period.start_at.to_date.beginning_of_month
        (0..2).map do |i|
          month_start = first_month + i.months
          month_end   = month_start.end_of_month
          hours = by_day.select { |d, _| d >= month_start && d <= month_end }.values.sum
          { label: I18n.l(month_start, format: '%b'), hours: hours.round(1),
            current: today >= month_start && today <= month_end }
        end
      else
        (period.start_at.to_date..period.end_at.to_date).map do |date|
          { label: day_bucket_label(date, period.key),
            hours: (by_day[date] || 0.0).round(1),
            current: date == today }
        end
      end
    end

    # Weekday abbreviation for the week view (Sunday-first array indexed by wday),
    # plain day-of-month number for the longer daily views.
    def day_bucket_label(date, period_key)
      period_key == 'this_week' ? I18n.t('date.abbr_day_names')[date.wday] : date.day.to_s
    end

    def project_for_activity(activity)
      case activity.trackable
      when Ticket then activity.trackable.project
      when Note, Document, TimeSession then activity.trackable.project
      end
    end

    # FK-only variant without loading the project — avoids N+1 in the reject block.
    def project_id_for_activity(activity)
      case activity.trackable
      when Ticket, Note, Document, TimeSession then activity.trackable.project_id
      end
    end
  end
end
