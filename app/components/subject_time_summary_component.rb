# frozen_string_literal: true

# Header hours chip for a time subject (Ticket or Meeting): the booked total as
# a clock reading, the billing status in the tooltip, and — behind a click —
# the two-column capture popover (form + booked time), lazily loaded from
# TimeSessionsController#subject_popover. While the subject has no booked time
# it renders the quiet capture entry ("Zeit eintragen …") instead, for users
# who may write time; nothing at all otherwise. The old billing-assignment
# popover is gone: assigning is a monthly task and lives in the times list
# (designer handoff "Uebergabe Tickets" §9).
class SubjectTimeSummaryComponent < ViewComponent::Base
  def initialize(subject:, user:, mode: 'verbose')
    super()
    @subject = subject
    @user = user
    @mode = mode
    @summary = SubjectTimeSummaryService.call(subject: subject, user: user)
  end

  def render?
    booked_time? || can_capture_time?
  end

  def booked_time?
    @summary.present? && total_minutes.positive?
  end

  def total_minutes
    return @summary[:total_minutes].to_i if @summary&.key?(:total_minutes)

    (@summary&.dig(:hours).to_f * 60).round
  end

  # ProjectPolicy directly with @user (like SubjectTimeSummaryService), not
  # helpers.policy: the component answers for the user it was given, independent
  # of the rendering controller's session.
  def can_capture_time?
    return false unless @user

    ProjectPolicy.new(@user, @subject.project).area_access?(:time_sessions, :write)
  end

  def chip_class
    "js-time-chip-#{@subject.id}"
  end

  # The span create.turbo_stream.erb updates after a capture, so the sum grows
  # without replacing the chip (and with it the open popover).
  def value_dom_id
    "subject_time_chip_value_#{@subject.id}"
  end

  def popover_frame_id
    "subject_time_popover_#{@subject.id}"
  end

  def popover_src
    helpers.subject_popover_path_for(@subject)
  end

  def chip_title
    return capture_label unless booked_time?

    billing_status_text.presence || I18n.t('components.subject_time_summary.show_time_tracking')
  end

  # The zero-state entry. "Zeit eintragen" next to a MEETING is ambiguous — the
  # meeting header already shows a time, its duration — so meetings say
  # "Aufwand buchen" (user, 05.09.2026).
  def capture_label
    key = @subject.is_a?(Meeting) ? 'capture_effort' : 'capture_time'
    I18n.t("components.subject_time_summary.#{key}")
  end

  private

  # The word every surface says, through the one helper. '' rather than nil,
  # because the title rejects the empty ones.
  def billing_status_text
    helpers.time_billing_state_label(@summary[:billing_status], percent: @summary[:percent]).to_s
  end
end
