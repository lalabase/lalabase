# frozen_string_literal: true

# The lane of an inbox: what the chosen notification is about, beside the list, for the
# inbox of one organisation (Organisations::NotificationsController) and for the inbox
# above the organisations (AllInboxesController, which renders it inside the tenant of
# the row's organisation). One owner of what the lane loads and which partial draws it,
# so both pages show the same lane, whole (doc: cross_org_inbox_s3_plan.md §5.2).
# What a row opens is not decided here: Inbox::LaneKind answers it (a ticket inline, an
# object with a display of its own in a nested frame, a card for an event without one).
module InboxLane
  extend ActiveSupport::Concern

  # The state of the lane for each body Inbox::LaneKind names.
  LANE_STATES = { inline: :ticket, frame: :kind, card: :card }.freeze
  # The states in which the lane shows what the row is about, with the inbox's own head.
  LANE_SHOWN_STATES = LANE_STATES.values.freeze

  included do
    helper_method :inbox_pane_partial, :inbox_lane_frame_path
  end

  private

  # Inbox pane loader: reads params[:notification], finds the notification through the
  # policy scope, asks Inbox::LaneKind what it opens and sets @selected_notification,
  # @lane_kind, @project, @pane_state, @new_activities, @lane_row_bundle (and @ticket
  # for a ticket). States:
  #   :ticket        a ticket, rendered inline
  #   :kind          an object with a display of its own, in a nested frame
  #   :card          an event without a display, or one whose object is gone
  #   :unauthorized  the object's own policy refuses
  #   :non_ticket    a subject the lane does not know: a notice with a link
  #   :missing       no such row for this person
  def load_inbox_pane_context
    @pane_state = :missing
    # Through the policy scope (Notification.accessible_for): a row the person may
    # not see, a ticket of a lost area say, is no row to select.
    notification = lane_rows.find_by(id: params[:notification])
    return unless notification

    @selected_notification = notification
    @lane_kind = Inbox::LaneKind.for(notification)

    # A subject without an entry keeps navigating to its full view.
    unless @lane_kind
      @pane_state = :non_ticket
      return
    end

    @ticket = @lane_kind.target if @lane_kind.body == :inline
    @project = @lane_kind.project
    return unless @project
    return unless lane_object_allowed?

    # "What was new" block: the unread notifications of this subject are
    # exactly what the user has not yet seen. Loaded NOW —
    # i.e. before the 5s cascade sets them to read — and then remains
    # as a snapshot in the pane (the mark-read stream swaps only
    # pills + master, not the pane). No separate last_visit tracking
    # needed: the unread state IS the "since-last-visit" information.
    # The subject is the selected notification's own (the ticket, or the project
    # with all its events: a row about a project is a bundle of unlike events).
    # Through the policy scope, the inbox rule (spec/architecture/notification_read_guard_spec.rb):
    # an event of an area the person may not read is no line here. Newest event
    # first by when it happened, the time each line prints, not by when its row
    # reached the inbox (a row the fanout wrote late would stand above later events).
    @new_activities = lane_rows
                      .channel_in_app
                      .where(notifiable_type: notification.notifiable_type, notifiable_id: notification.notifiable_id)
                      .unread
                      .includes(:actor)
                      .by_happened_at
    @lane_row_bundle = lane_row_bundle(notification)

    # DELIBERATELY no more immediate mark_as_read — the user should be able to
    # glance briefly before the status is committed. A Stimulus
    # controller in the pane (see pane_mark_read_delay_controller.js) fires
    # a PATCH /mark_read after ~5s, if the notification is still open.
    @pane_state = LANE_STATES.fetch(@lane_kind.body)
  end

  # The person's notifications in this organisation, through the policy scope: the one
  # relation every read of the lane starts from.
  def lane_rows
    policy_scope(current_user.notifications).for_current_tenant_user(current_user)
  end

  # How many notifications the list of this request bundles into the open row (the list
  # state travels in the lane's address, and the including controller names it as
  # filter_params). The lane redraws that row, and the row decides its title by this
  # number: a row for one event of a project shows the object's title, a bundle the
  # project's name. Asked of the list's own presenter, so both draw the same row.
  def lane_row_bundle(notification)
    filters = Inbox::MasterListPresenter.clean_filters(filter_params.to_h)
    rows = Inbox::MasterListPresenter.narrow(lane_rows.channel_in_app, filters, time_zone: current_user.time_zone)
    Inbox::MasterListPresenter.bundle_size(notification, scope: rows, params: filters)
  end

  # The object's own policy, asked before anything of it is drawn: the ticket the inbox
  # renders, and the object whose frame the lane will load (its controller asks again).
  # A card draws nothing of an object: it shows what the row already shows.
  def lane_object_allowed?
    return true if @lane_kind.body == :card

    authorize @lane_kind.target, :show?
    true
  rescue Pundit::NotAuthorizedError
    @pane_state = :unauthorized
    false
  end

  # Called only by the authorized pane. A preview belongs to its document, never
  # to a version named independently by the address. A removed/foreign version
  # falls back to the document, as on the knowledge page.
  def inbox_lane_frame_path
    target = @lane_kind.target
    preview = params[KnowledgeFilterHelper::PREVIEW_PARAM]
    if target.is_a?(Document) && preview.is_a?(String)
      version = target.document_versions.find_by(id: preview)
      if version
        return preview_organisation_project_document_path(
          target.organisation_id, target.project_id, target,
          version_id: version.id, frame: 'content', frame_id: Inbox::ObjectFrame::FRAME_ID
        )
      end
    end

    @lane_kind.frame_path
  end

  def inbox_pane_partial
    case @pane_state
    when *LANE_SHOWN_STATES then 'organisations/notifications/pane'
    when :unauthorized  then 'organisations/notifications/pane_unauthorized'
    when :non_ticket    then 'organisations/notifications/pane_non_ticket'
    else                     'organisations/notifications/pane_missing'
    end
  end
end
