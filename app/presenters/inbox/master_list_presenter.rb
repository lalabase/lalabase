# frozen_string_literal: true

# Encapsulates the complete display logic of the inbox master list:
# - Filters (state_filters, search, project, event_type)
# - Pagination (Pagination::Page)
# - Grouping by date (for the grouped view)
# - Empty-state logic
# - Active-filter detection
#
# Used both in Controller#index and in turbo_stream re-renders, so that the
# initial and live update take the exact same code path — date headers
# disappear automatically when the last item of a group is removed, the
# empty state appears as soon as nothing is left at all.
module Inbox
  class MasterListPresenter
    PAGE_SIZE = 50

    # The four status views the list offers, one at a time, in the order of
    # the head (user, 2026-11-10: "Alle" first and the default, "Gelesen"
    # new). Each is a set of state filters; a URL that names another set (an
    # old bookmark with "unread" and "archived", say) shows its rows and marks
    # no view as active, and its empty list says so (empty_reason
    # :other_filter).
    STATUS_VIEWS = {
      'all' => %w[read unread],
      'unread' => %w[unread],
      'read' => %w[read],
      'archived' => %w[archived]
    }.freeze

    # The headings of the grouped view, the most recent period first: a bundle
    # stands under the period of the latest arrival among its rows.
    PERIODS = %i[today yesterday this_week older].freeze

    # What narrows the rows beyond the status view. `org` exists only on the
    # inbox above the organisations (AllInboxesController): one organisation of
    # the list.
    NARROWING = %i[search project_id event_type period org].freeze

    # The status view a set of state filters names, or nil. No filter at all
    # is the default list (unread and read), so it is "all" as well.
    def self.status_view(state_filters)
      filters = Array(state_filters).compact_blank.uniq.sort
      return 'all' if filters.empty?

      STATUS_VIEWS.find { |_key, set| set.sort == filters }&.first
    end

    # The filters of an inbox address as the list reads them, for both inboxes
    # (of one organisation, above them). A type that does not exist (a hand-made
    # address) is no filter: Postgres refuses the value of its enum, and the page
    # would answer 500. The period is one of the time area's presets; the whole
    # time (the default) and an unknown value are no narrowing and leave the
    # address.
    def self.clean_filters(filters)
      filters.delete('event_type') unless Notification.event_types.key?(filters['event_type'])
      period = TimeSessions::ListPeriod.normalize_for_table(filters['period'])
      period == TimeSessions::ListPeriod::TABLE_DEFAULT ? filters.delete('period') : filters['period'] = period
      filters
    end

    # The rows of `scope` the cleaned filters leave: project, type, search, period.
    def self.narrow(scope, filters, time_zone:)
      scope.apply_filters(filters).active_in_period(filters['period'], time_zone: time_zone)
    end

    # How many notifications the list bundles into the row of this notification's
    # subject, under the filters the rows were narrowed with (group_total, asked for
    # ONE row). For a caller that redraws a single row of the list (the lane marks
    # its open row): the row decides its title by this number, like the row the list
    # drew. 1 in the chronological list, where every row is one notification.
    def self.bundle_size(notification, scope:, params:)
      bundle = bundle_of(notification, scope: scope, params: params)
      bundle ? [bundle.count, 1].max : 1
    end

    # Whether that bundle has an unread row, under the same filters: what draws
    # the row bold (group_unread, for ONE row). The lane starts its read timer
    # for a read open row only then: in the archived and the read view a bundle
    # holds no unread row, and in the chronological list a row stands for itself
    # alone, so opening a row there reads no other row of its subject.
    def self.bundle_unread?(notification, scope:, params:)
      bundle = bundle_of(notification, scope: scope, params: params)
      bundle ? bundle.unread.exists? : false
    end

    # The rows the list of these filters bundles with this notification's
    # subject, its status view included; nil in the chronological list.
    def self.bundle_of(notification, scope:, params:)
      params = params.to_h.with_indifferent_access
      return unless (params[:view_mode].presence || 'grouped').to_s == 'grouped'

      with_states(scope, state_filters(params))
        .where(notifiable_type: notification.notifiable_type, notifiable_id: notification.notifiable_id)
    end
    private_class_method :bundle_of

    # The state filters an address names: state_filters[], or the single `state`.
    def self.state_filters(params)
      arr = Array(params[:state_filters]).reject(&:blank?)
      arr << params[:state] if arr.empty? && params[:state].present?
      arr.uniq
    end

    # The rows in the states the filters name; without a filter everything but the archive.
    def self.with_states(scope, filters)
      return scope.where.not(state: Notification.states[:archived]) if filters.empty?

      allowed = []
      allowed += %w[queued sent delivered] if filters.include?('unread')
      allowed << 'read'     if filters.include?('read')
      allowed << 'archived' if filters.include?('archived')
      scope.where(state: allowed)
    end

    # page: the page as the request names it (`params[:page]` of the controller;
    # `params:` here are the cleaned filters). time_zone: the zone the reader's
    # days run in (User#time_zone), for the period headings.
    def initialize(page:, scope:, params:, time_zone: Time.zone, through_page: nil)
      @page = page
      @scope = scope
      @params = params
      @time_zone = time_zone
      @through_page = through_page
      compute!
    end

    attr_reader :pagy, :notifications, :grouped_notifications, :view_mode,
                :total_count, :active_state_filters, :first_page

    def grouped?
      view_mode == 'grouped'
    end

    # Loads the rows of the page now, with what a row reads as its title. For a
    # page that renders without a tenant (the inbox above the organisations): the
    # caller runs this inside the tenant-free read, afterwards a row loads nothing.
    def load!
      @notifications.load
      Notifications::InboxQuery.preload_titles(@notifications)
      self
    end

    # Number of notifications that belong to the same notifiable (ticket) as
    # the passed one — basis for the "N updates" badge. Minimum 1.
    def group_total(notification)
      @group_total.fetch([notification.notifiable_type, notification.notifiable_id], 1)
    end

    # Of those, the unread ones — controls the unread styling of the bundled row:
    # the row counts as unread as long as ANY of its notifications is unread
    # (not just the displayed representative).
    def group_unread(notification)
      @group_unread.fetch([notification.notifiable_type, notification.notifiable_id], 0)
    end

    delegate :empty?, to: :notifications

    def status_view
      self.class.status_view(active_state_filters)
    end

    # A search, a project or a type narrows the rows beyond the status view.
    def narrowed?
      NARROWING.any? { |key| @params[key].present? }
    end

    # The list state as query parameters, for the links of a list a stream
    # redraws: the request it answers is an action, so the links cannot read
    # their filters from its address. Search and project included, or the
    # first click in a redrawn list would drop both from the address.
    def query_context
      context = {}
      context[:state_filters] = active_state_filters if active_state_filters.any?
      context[:view_mode] = view_mode unless grouped?
      NARROWING.each { |key| context[key] = @params[key] if @params[key].present? }
      context
    end

    # Why the list is empty, for the sentence it shows: a narrowed list found
    # nothing, an empty unread view means everything is read (a good state,
    # not an error), the archive and the whole list simply hold nothing yet.
    # A set of states that is none of the three views (an old address) is no
    # empty inbox: its sentence leads to the view that shows everything.
    def empty_reason
      return :no_match if narrowed?

      case status_view
      when 'unread' then :all_read
      when 'read' then :nothing_read
      when 'archived' then :nothing_archived
      when 'all' then :nothing_yet
      else :other_filter
      end
    end

    private

    def compute!
      @active_state_filters = derive_active_state_filters
      @filtered = apply_state_filters(@scope)
      @view_mode = (@params[:view_mode].presence || 'grouped').to_s
      @total_count = @filtered.count
      @group_total = {}
      @group_unread = {}

      if grouped?
        compute_grouped!
      else
        @notifications = @filtered.for_notification_center.recent
        # One row per notification: the total counted above is this list's count.
        @notifications = paginate(@notifications, count: @total_count)
      end
    end

    # Grouping = bundling per notifiable (ticket): ONE row per ticket,
    # represented by the notification whose latest event HAPPENED last
    # (Notification#happened_at), so its line says what the ticket's newest
    # event was. The bundle stands where the newest ARRIVAL among its rows
    # stands (last_event_at, the order of every list): a row the fanout wrote
    # late puts its ticket on top, though an older row may speak for it.
    # Pagination runs at the ticket level (PAGE_SIZE tickets/page), not at the
    # notification level. A ticket appears globally only ONCE, under the day of
    # that arrival. group_total/group_unread provide the bundle counts.
    def compute_grouped!
      bundles = representatives.arel.as('bundles')
      # Newest arrival of the bundle first, then the id: the rule of
      # Notification.recent, for a bundle. Ordered on the narrow side of the join.
      rep_scope = Notification.joins(bundle_rows(bundles))
                              .select(Notification.arel_table[Arel.star], bundles[:bundle_arrived_at])
                              .for_notification_center
                              .order(bundles[:bundle_arrived_at].desc, bundles[:id].desc)

      # Counts over the ENTIRE filtered scope (not just this page), so that
      # the badge shows the real total count per ticket.
      @group_total = count_by_notifiable(@filtered)
      @group_unread = count_by_notifiable(@filtered.unread)

      # One key per bundle, the same (notifiable_type, notifiable_id) pairs the
      # DISTINCT ON picks a representative for: its size is the number of rows,
      # and the page takes it instead of a second COUNT over the subquery.
      reps = paginate(rep_scope, count: @group_total.size)

      @grouped_notifications = group_by_period(reps)
      @notifications = reps
    end

    # DISTINCT ON: one representative per notifiable, the row whose latest
    # event happened last; ORDER BY must lead with the DISTINCT columns. The id
    # only makes the choice stable between rows of the same moment. The window
    # runs before DISTINCT ON, over every row of the bundle: bundle_arrived_at
    # is the bundle's newest arrival, what compute_grouped! orders by (desc,
    # then the id, as Notification.recent does) and group_by_period reads.
    # Only the id and the window: this sort runs over every row of the filtered
    # inbox and no LIMIT reaches into it, so whole rows (the payload with them)
    # would make it wide. The page joins its bundles' rows back (#bundle_rows).
    def representatives
      bundle = 'notifications.notifiable_type, notifications.notifiable_id'
      @filtered.reorder(nil)
               .select(Arel.sql("DISTINCT ON (#{bundle}) notifications.id, " \
                                "MAX(notifications.last_event_at) OVER (PARTITION BY #{bundle}) AS bundle_arrived_at"))
               .order(Arel.sql("#{bundle}, #{Notification::HAPPENED_AT_SQL} DESC, notifications.id DESC"))
    end

    # The rows of the representatives, by id: an inner join, so the page reads
    # no row the filtered inbox does not hold.
    def bundle_rows(bundles)
      notifications = Notification.arel_table
      notifications.join(bundles).on(bundles[:id].eq(notifications[:id])).join_sources
    end

    # A row action refreshes the pages currently on screen, including pages
    # appended by endless scroll. Keep the original offset and extend the limit;
    # the scroller resumes AFTER the last rendered page, still in PAGE_SIZE steps.
    # count: the total, where the caller counted it already (Pagination::Page.of).
    def paginate(scope, count: nil)
      # A page behind the end stays EMPTY here (the default): the scroller appends
      # what it gets, and the last page again would be the same rows twice.
      @pagy, rows = Pagination::Page.of(scope, page: @page, limit: PAGE_SIZE, count: count)
      @first_page = @pagy.page
      last_page = @through_page.to_s.to_i.clamp(first_page, [@pagy.pages, first_page].max)
      rows = rows.limit(@pagy.limit * (last_page - first_page + 1))
      @pagy = @pagy.with_page(last_page) if last_page != first_page
      rows
    end

    # { period => representatives } in PERIODS order, empty periods left out.
    # A representative counts by the day of its bundle's newest arrival
    # (bundle_arrived_at), the moment the bundles are ordered by.
    # "This week" starts on the week's Monday; yesterday counts as yesterday
    # even when it was in the previous week. The days are the reader's: in
    # the app zone (UTC) the hour after a Berlin midnight still belongs to the
    # day before, and all of that day would read "Heute".
    def group_by_period(reps)
      today = Time.current.in_time_zone(@time_zone).to_date
      grouped = reps.group_by do |notification|
        date = notification.bundle_arrived_at.in_time_zone(@time_zone).to_date
        if date >= today then :today
        elsif date == today - 1 then :yesterday
        elsif date >= today.beginning_of_week then :this_week
        else :older
        end
      end
      PERIODS.filter_map { |period| [period, grouped[period]] if grouped[period] }.to_h
    end

    def derive_active_state_filters
      self.class.state_filters(@params)
    end

    def apply_state_filters(scope)
      self.class.with_states(scope, active_state_filters)
    end

    # { [notifiable_type, notifiable_id] => count } over the scope.
    # reorder(nil) removes any ORDER BY columns that would otherwise have to go
    # into the GROUP BY clause (Postgres error).
    def count_by_notifiable(scope)
      scope.reorder(nil).group(:notifiable_type, :notifiable_id).count
    end
  end
end
