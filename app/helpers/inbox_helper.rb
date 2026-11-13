# frozen_string_literal: true

# Addresses and labels of the inbox list head (organisations/notifications).
# A link of the head changes one dimension of the list and keeps the others;
# it never carries the open notification or a page number along. A list
# rendered by a stream answers an action address, not the inbox: it passes
# the list state it was given (query:) instead of the request's query.
module InboxHelper
  # The dimensions of the list, the only keys a link or a form of the head
  # carries along. An allowlist, not a denylist: a stray key of a hand-made
  # address (partial=, format=, or a name like submit= that would shadow a
  # method of the form it is written into) must not travel with the list.
  INBOX_LIST_PARAMS = %w[state_filters state view_mode search project_id event_type period].freeze
  # One organisation of the inbox above the organisations. It travels only
  # there: inside an organisation the address itself names it.
  INBOX_ORGANISATION_PARAM = 'org'

  # The list address with one status view: unread, all or archived.
  def inbox_status_view_url(view, query: nil)
    query = inbox_list_query(query).except('state', 'state_filters')
    query['state_filters'] = Inbox::MasterListPresenter::STATUS_VIEWS.fetch(view)
    inbox_list_url(query)
  end

  def inbox_view_mode_url(mode)
    inbox_list_url(inbox_list_query.merge('view_mode' => mode))
  end

  # The list address without search, project and type: the status view stays.
  def inbox_reset_narrowing_url(query: nil)
    inbox_list_url(inbox_list_query(query).except('search', 'project_id', 'event_type', 'period',
                                                  INBOX_ORGANISATION_PARAM))
  end

  # The list address with one notification open in the lane.
  def inbox_notification_url(notification, query: nil)
    inbox_list_url(inbox_list_query(query).merge('notification' => notification.id))
  end

  # The type filter has no control of its own any more: an old address or a
  # link from elsewhere sets it. The type that narrows the list now, or nil;
  # the head shows it as a chip that removes it.
  def inbox_event_type_filter
    inbox_list_query['event_type'].presence
  end

  # The type as a noun ("Erwähnung"), from the model's own words
  # (activerecord.enums). The row's event_short is a verb phrase ("hat dich
  # erwähnt") and reads wrong behind "Typ:".
  def inbox_event_type_label(event_type)
    t("activerecord.enums.notification.event_type.#{event_type}", default: event_type.to_s.humanize)
  end

  def inbox_without_event_type_url
    inbox_list_url(inbox_list_query.except('event_type'))
  end

  # The rest of the list state as hidden fields of a head form, so that the
  # search keeps the status view and the project keeps the search.
  def inbox_hidden_query_fields(except:)
    fields = inbox_list_query.except(*except).flat_map do |key, value|
      case value
      when Array then value.grep(String).map { |item| hidden_field_tag("#{key}[]", item, id: nil) }
      when String then [hidden_field_tag(key, value, id: nil)]
      else [] # a nested hash from a hand-made address is no list state
      end
    end
    safe_join(fields)
  end

  # The inbox above the organisations (AllInboxesController) and the inbox of one
  # organisation render the same list. What differs (where the list lives, whether
  # a row names its organisation) hangs on this one question: a list rendered
  # without an organisation is the one above them.
  def inbox_above_organisations?
    current_organisation.nil?
  end

  # Where the list lives: the address its links, forms and paging lead to.
  def inbox_list_path
    inbox_above_organisations? ? all_inboxes_path : organisation_notifications_path(current_organisation)
  end

  # A row of the inbox above the organisations leaves for the inbox of its
  # organisation, with the row open in the lane and the status view kept.
  def inbox_notification_in_organisation_url(notification, query: nil)
    states = inbox_list_query(query)['state_filters'].presence || Inbox::MasterListPresenter::STATUS_VIEWS.fetch('all')
    organisation_notifications_path(notification.organisation_id, state_filters: states, notification: notification.id)
  end

  # An organisation in the select of the inbox above the organisations: its
  # name, with the unread count while there is one ("Muster GmbH (3)").
  def inbox_organisation_option(organisation)
    return organisation[:name] unless organisation[:unread].positive?

    "#{organisation[:name]} (#{organisation[:unread]})"
  end

  def inbox_period_label(period)
    t("views.organisations.notifications.periods.#{period}")
  end

  private

  # A type that does not exist is no filter (the controller reads it the
  # same way), so it does not travel either.
  def inbox_list_query(query = nil)
    keys = inbox_above_organisations? ? INBOX_LIST_PARAMS + [INBOX_ORGANISATION_PARAM] : INBOX_LIST_PARAMS
    list = (query || request.query_parameters).to_h.deep_stringify_keys.slice(*keys)
    list.delete('event_type') unless Notification.event_types.key?(list['event_type'])
    list
  end

  def inbox_list_url(query)
    query.present? ? "#{inbox_list_path}?#{query.to_query}" : inbox_list_path
  end
end
