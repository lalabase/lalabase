# frozen_string_literal: true

# The inbox above the organisations ("Gesamt-Inbox", GET /inbox): the list of the
# organisation's inbox with a wider reach, for a person with several organisations.
# Every row names its organisation; a click leaves for that organisation's inbox
# with the row open. The actions of a row (read, unread, archive, back from the
# archive) work in place.
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

  def index
    return redirect_to(single_inbox_path) if single_inbox_path

    load_list
  end

  # The actions of a row's "···" menu, in place: the row changes, the list stays
  # where it is. The list state travels in the address of the action (the row's
  # form carries it), so the answer redraws the list the reader was looking at.
  ROW_ACTIONS.each_key do |name|
    define_method(name) { change_row(ROW_ACTIONS.fetch(name)) }
  end

  private

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
      format.html do
        query = @presenter.query_context
        query[:page] = @presenter.first_page if @presenter.first_page > 1
        redirect_to all_inboxes_path(query)
      end
    end
  end

  def reach
    @reach ||= PersonalAccessToken::Reach.for_person(current_user)
  end

  # Rows, counts per organisation and the number at "Ungelesen", for the page and
  # for the answer of a row action alike.
  def load_list
    filters = Inbox::MasterListPresenter.clean_filters(filter_params.to_h)
    Notifications::InboxQuery.reading(user: current_user, reach: reach, organisation_id: params[:org]) do |rows, counts|
      @inbox_organisations = counts
      @presenter = Inbox::MasterListPresenter.new(
        pagy_helper: self,
        scope: Inbox::MasterListPresenter.narrow(rows, filters, time_zone: current_user.time_zone),
        params: filters, time_zone: current_user.time_zone,
        through_page: action_name == 'index' ? nil : params[:through_page]
      ).load!
    end
    @unread_count = shown_organisations.sum { |organisation| organisation[:unread] }
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
