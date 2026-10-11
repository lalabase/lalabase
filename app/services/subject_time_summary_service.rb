# frozen_string_literal: true

# Aggregates the booked time on a time subject (Ticket or Meeting) for the header
# hours chip: total, viewing scope (all/own) and a combined billing status. Returns
# nil when the user may not view the subject's time sessions at all.
class SubjectTimeSummaryService
  attr_reader :subject, :user

  def self.call(subject:, user:)
    new(subject: subject, user: user).call
  end

  def initialize(subject:, user:)
    @subject = subject
    @user = user
  end

  def call
    return nil unless can_view_time_sessions?

    # ONE grouped query for all of it. It used to be a SUM plus a full load of
    # every booking of the ticket, to count them in Ruby.
    buckets = TimeSessions::BucketTotals.call(scope: visible_time_sessions)
    minutes = buckets.transform_values { |bucket| bucket[:minutes] }
    total_minutes = minutes.values.sum

    {
      total_minutes: total_minutes,
      hours: (total_minutes / 60.0).round(2),
      scope: viewing_scope,
      billing_status: TimeSessions::SubjectBillingStatus.call(
        counts: buckets.transform_values { |bucket| bucket[:sessions] }
      ),
      # For the chip's share bar, the same one the time list and the ticket
      # table's billing column draw (plan §4).
      shares: minutes,
      percent: TimeSessions::SubjectBillingStatus.percent_billed(minutes: minutes),
      can_view: true
    }
  end

  private

  # Nil (no chip) only for a row that denies viewing outright; without a row the
  # chip shows with scope :none. It used to ask User#time_session_permission_for,
  # the settings form's helper, whose unsaved default row stood in for "no row".
  def can_view_time_sessions?
    return true if user.account_admin_in?(subject.organisation)

    permission = user.time_session_permissions.backed_by_project_access.find_by(project: subject.project)
    permission.nil? || permission.can_view_own? || permission.can_view_all?
  end

  # The all / own / none tier and the matching narrowing come from ONE owner,
  # TimeSessions::ViewingScope (shared with the chat report tool), so the chip and
  # the chat can never disagree about whose hours a number covers. Fail-closed: a
  # user without a persisted permission row is :none (before the extraction the
  # unsaved default row reported :own with nothing visible).
  def viewing_scope
    viewing.tier
  end

  def viewing
    @viewing ||= TimeSessions::ViewingScope.call(user: user, project: subject.project)
  end

  # No includes(:time_session_group) any more: the billing fold below reads the
  # session's own billed flag and its group_id, both already on the row.
  def visible_time_sessions
    @visible_time_sessions ||= viewing.apply(subject.time_sessions)
  end
end
