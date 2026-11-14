# frozen_string_literal: true

# The lane of an inbox: the ticket of the chosen notification beside the list, for the
# inbox of one organisation (Organisations::NotificationsController) and for the inbox
# above the organisations (AllInboxesController, which renders it inside the tenant of
# the row's organisation). One owner of what the lane loads and which partial draws it,
# so both pages show the same lane, whole (doc: cross_org_inbox_s3_plan.md §5.2). V1
# knows one kind, the ticket; the registry of kinds (S4) grows out of this owner.
module InboxLane
  extend ActiveSupport::Concern

  included do
    helper_method :inbox_pane_partial
  end

  private

  # Inbox pane loader: reads params[:notification], loads the notification +
  # associated ticket (with Pundit), marks the notification as read
  # and sets @selected_notification + @ticket + @project + @pane_state.
  # See doc/inbox_feature_spec.md chapter 4.4.
  def load_inbox_pane_context
    @pane_state = :missing
    # Through the policy scope (Notification.accessible_for): a row the person may
    # not see, a ticket of a lost area say, is no row to select.
    notification = policy_scope(current_user.notifications)
                   .for_current_tenant_user(current_user)
                   .find_by(id: params[:notification])
    return unless notification

    @selected_notification = notification
    notifiable = notification.notifiable

    # V1: Only tickets get the pane pattern. Other notifiables
    # keep navigating via "Open in ticket". See spec 4.6.
    unless notifiable.is_a?(Ticket)
      @pane_state = :non_ticket
      return
    end

    @ticket   = notifiable
    @project  = notifiable.project
    return unless @project

    # Pundit: can the user see the ticket? If not: unauthorized pane.
    begin
      authorize @ticket, :show?
    rescue Pundit::NotAuthorizedError
      @pane_state = :unauthorized
      return
    end

    # "What was new" block: the unread notifications of this ticket are
    # exactly what the user has not yet seen. Loaded NOW —
    # i.e. before the 5s cascade sets them to read — and then remains
    # as a snapshot in the pane (the mark-read stream swaps only
    # pills + master, not the pane). No separate last_visit tracking
    # needed: the unread state IS the "since-last-visit" information.
    # Through the policy scope, the inbox rule (spec/architecture/notification_read_guard_spec.rb).
    @new_activities = policy_scope(current_user.notifications)
                      .for_current_tenant_user(current_user)
                      .channel_in_app
                      .where(notifiable_type: 'Ticket', notifiable_id: @ticket.id)
                      .unread
                      .includes(:actor)
                      .recent

    # DELIBERATELY no more immediate mark_as_read — the user should be able to
    # glance briefly before the status is committed. A Stimulus
    # controller in the pane (see pane_mark_read_delay_controller.js) fires
    # a PATCH /mark_read after ~5s, if the notification is still open.
    @pane_state = :ticket
  end

  def inbox_pane_partial
    case @pane_state
    when :ticket        then 'organisations/notifications/pane_ticket'
    when :unauthorized  then 'organisations/notifications/pane_unauthorized'
    when :non_ticket    then 'organisations/notifications/pane_non_ticket'
    else                     'organisations/notifications/pane_missing'
    end
  end
end
