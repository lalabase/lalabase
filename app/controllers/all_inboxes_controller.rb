# frozen_string_literal: true

# The inbox above the organisations ("Gesamt-Inbox", GET /inbox): the list of the
# organisation's inbox with a wider reach, for a person with several organisations.
# Every row names its organisation; a click leaves for that organisation's inbox
# with the row open. The actions of a row (read, unread, archive, back from the
# archive) work in place, and so does the bulk bar on the rows that are ticked
# (read, archive). The page follows changes made elsewhere through one
# signal per person (Notifications::Streams.all_inboxes) and its own redraw
# (index as turbo_stream).
#
# Runs WITHOUT a tenant, like the cockpit, and never sets the session's
# organisation: looking at a row of organisation B must not move the organisation
# another tab works in. `org` (one organisation of the list) is therefore not
# called organisation_id, the name ApplicationController reads the tenant from.
#
# The rows come from Notifications::InboxQuery, the reader of the token inbox
# (API, MCP), with the reach of the person: recipient, in-app, and per
# organisation the one inbox rule (Notification.readable). Filters, paging and
# grouping are Inbox::MasterListPresenter's, and the list partials are those of
# organisations/notifications: the same list, not a second one.
#
# ⚠️ Everything a row shows is loaded inside the query's tenant-free read
# (presenter.load!). The views run after it, and a tenanted association loaded
# there raises NoTenantSet. Do not read a tenanted model in this action or its
# views outside that block.
class AllInboxesController < ApplicationController
  skip_before_action :load_tenant_from_session

  # An organisation the person cannot reach, one that does not exist and a
  # malformed id answer alike.
  rescue_from Notifications::InboxQuery::InvalidArgument do
    head :not_found
  end

  # The action of a row and the policy question it asks. One list for the routes,
  # the actions below and the actor's vocabulary.
  ROW_ACTIONS = {
    'mark_read' => { change: 'read', query: :mark_read? },
    'mark_unread' => { change: 'unread', query: :mark_unread? },
    'archive' => { change: 'archive', query: :archive? },
    # Whoever may archive may bring it back out, as in the inbox of an organisation.
    'unarchive' => { change: 'unarchive', query: :archive? }
  }.freeze

  # The action of the bulk bar and the policy question it asks.
  SELECTION_ACTIONS = {
    'mark_selection_read' => { change: 'read', query: :mark_all_read?, said: 'marked_read' },
    'archive_selection' => { change: 'archive', query: :archive_all?, said: 'archived' }
  }.freeze

  # The most rows one bulk action takes: ten pages of the list. More would hold
  # locks on thousands of rows in one transaction, and far above it the request
  # runs into the limit of parameters the server reads at all.
  MAX_SELECTION = 500

  def index
    return redirect_to(single_inbox_path) if single_inbox_path

    load_list
    respond_to do |format|
      format.html
      # The live redraw (all_inboxes_live_controller, after a signal on
      # Notifications::Streams.all_inboxes): the list and every count, or with
      # part=counts the counts alone. The same reader and the same list state in
      # the address as the page, no second path.
      format.turbo_stream do
        response.set_header('X-Inbox-Stamp', @stamp)
        @redraw_list = params[:part] != 'counts'
        render :live
      end
    end
  end

  # The actions of a row's "···" menu, in place: the row changes, the list stays
  # where it is. The list state travels in the address of the action (the row's
  # form carries it), so the answer redraws the list the reader was looking at.
  ROW_ACTIONS.each_key do |name|
    define_method(name) { change_row(ROW_ACTIONS.fetch(name)) }
  end

  # The actions of the bulk bar, on the rows that are ticked and on nothing else:
  # this page has no action on "everything", so a request without ids is refused.
  SELECTION_ACTIONS.each_key do |name|
    define_method(name) { change_selection(SELECTION_ACTIONS.fetch(name)) }
  end

  private

  # The ticked rows are found per organisation, each under its own tenant
  # (Notifications::Selection: the policy scope of every organisation the person
  # is an active member of, no read across organisations). An id that is not the
  # person's own visible in-app row there (foreign, hidden, gone, malformed) is
  # left out without a word, so no answer tells one from the other. The policy
  # is asked under the tenant of each organisation the selection touches, and
  # the write (Actors::ChangeNotificationStates, one transaction over all of
  # them) sets the tenant itself; the session keeps its organisation.
  def change_selection(action)
    ids = selected_ids
    return refuse_selection(t('flash.notifications.nothing_selected')) if ids.empty?
    return refuse_selection(t('flash.all_inboxes.too_many_selected', count: MAX_SELECTION)) if ids.size > MAX_SELECTION

    # Reject an unreachable/malformed list filter before committing the write.
    Notifications::InboxQuery.new(user: current_user, reach: reach, organisation_id: params[:org])

    found = Notifications::Selection.call(user: current_user, ids: ids)
    found.each_key { |organisation| ActsAsTenant.with_tenant(organisation) { authorize :notifications, action[:query] } }
    result = Actors::ChangeNotificationStates.call(ids_by_organisation: found, change: action[:change],
                                                   current_user: current_user)
    raise Actors::ActorError, result.errors unless result.success?

    # The number of rows the reader ticked and the write found: a ticket counts
    # once, however many notifications about it went along.
    rows = found.values.sum(&:size)
    @said = rows.zero? ? t('flash.all_inboxes.none_changed') : t("flash.all_inboxes.#{action[:said]}", count: rows)
    load_list

    respond_to do |format|
      format.turbo_stream { render :update }
      format.html { redirect_to all_inboxes_path(list_address), notice: @said }
    end
  end

  # The ids of the bulk bar: a list of strings, each once. Anything else (a
  # single value, a nested hash) is no selection.
  def selected_ids
    Array(params.permit(ids: [])[:ids]).compact_blank.uniq
  end

  # Nothing was changed, and the list on the screen stays as it is.
  def refuse_selection(message)
    respond_to do |format|
      format.turbo_stream do
        @said = message
        render :refused, status: :unprocessable_content
      end
      format.html do
        redirect_to all_inboxes_path(Inbox::MasterListPresenter.clean_filters(filter_params.to_h).except('page')),
                    alert: message
      end
    end
  end

  # The address of the list a redraw shows, for the answer without a stream.
  def list_address
    query = @presenter.query_context
    query[:page] = @presenter.first_page if @presenter.first_page > 1
    query
  end

  # The row is found through the inbox reader (the person's own, within reach,
  # still visible): everything else is no row. Policy and write then run under
  # the tenant of the ROW, for this block only; the session keeps its organisation.
  def change_row(action)
    notification = Notifications::InboxQuery.row(user: current_user, reach: reach, id: params[:id])
    return head(:not_found) unless notification

    # Reject an unreachable/malformed list filter before committing the write.
    # InboxQuery owns this validation for the index and the refresh as well.
    Notifications::InboxQuery.new(user: current_user, reach: reach, organisation_id: params[:org])

    ActsAsTenant.with_tenant(notification.organisation) do
      authorize notification, action[:query]
      result = Actors::ChangeNotificationState.call(notification: notification, change: action[:change],
                                                    current_user: current_user)
      raise Actors::ActorError, result.errors unless result.success?
    end
    @action_type = action_name
    load_list

    respond_to do |format|
      format.turbo_stream { render :update }
      format.html { redirect_to all_inboxes_path(list_address) }
    end
  end

  def reach
    @reach ||= PersonalAccessToken::Reach.for_person(current_user)
  end

  # Rows, counts per organisation and the number at "Ungelesen", for the page, the
  # live redraw and the answer of a row action alike. The stamp, counts and rows
  # must describe ONE snapshot: a row created and removed between these reads
  # must not leave a phantom row on screen carrying the original (current) stamp.
  def load_list
    ApplicationRecord.transaction(isolation: :repeatable_read) do
      @stamp = Notifications::InboxQuery.stamp(user: current_user, reach: reach)
      filters = Inbox::MasterListPresenter.clean_filters(filter_params.to_h)
      Notifications::InboxQuery.reading(user: current_user, reach: reach, organisation_id: params[:org]) do |rows, counts|
        @inbox_organisations = counts
        @presenter = Inbox::MasterListPresenter.new(
          pagy_helper: self,
          scope: Inbox::MasterListPresenter.narrow(rows, filters, time_zone: current_user.time_zone),
          params: filters, time_zone: current_user.time_zone,
          through_page: redraw? ? params[:through_page] : nil
        ).load!
      end
      @unread_count = shown_organisations.sum { |organisation| organisation[:unread] }
    end
  end

  # A redraw of a list already on the screen (a row action, the live redraw) keeps
  # the pages the endless scroll has added; a full visit starts at its page.
  def redraw?
    action_name != 'index' || request.format.turbo_stream?
  end

  # With fewer than two organisations there is nothing above them: the inbox of
  # the one organisation, or wherever a person without any belongs.
  def single_inbox_path
    return @single_inbox_path if defined?(@single_inbox_path)

    organisations = current_user.active_organisations.limit(2).to_a
    @single_inbox_path =
      case organisations.size
      when 0 then user_home_path(current_user)
      when 1 then organisation_notifications_path(organisations.first)
      end
  end

  # The organisations the list shows: all in view, or the one `org` names. The
  # number at "Ungelesen" counts what the list can show.
  def shown_organisations
    chosen = Lalabase::Uuid.dashed(params[:org].to_s)
    chosen ? @inbox_organisations.select { |organisation| organisation[:id] == chosen } : @inbox_organisations
  end

  # The dimensions of the list. No project: a project belongs to one organisation,
  # and the list narrows to an organisation first (`org`).
  def filter_params
    params.permit(:search, :event_type, :view_mode, :page, :period, :org, state_filters: [])
  end
end
