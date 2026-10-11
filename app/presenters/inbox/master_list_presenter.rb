# frozen_string_literal: true

# Encapsulates the complete display logic of the inbox master list:
# - Filters (state_filters, search, project, event_type)
# - Pagination (pagy)
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
    # The pagy helper needs a class instance that understands `params` and the
    # `pagy_*` helpers — the controller passes itself.
    def initialize(pagy_helper:, scope:, params:)
      @pagy_helper = pagy_helper
      @scope = scope
      @params = params
      compute!
    end

    attr_reader :pagy, :notifications, :grouped_notifications, :view_mode,
                :total_count, :active_state_filters

    def grouped?
      view_mode == 'grouped'
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

    def has_active_filters?
      @params[:search].present? ||
        @params[:project_id].present? ||
        @params[:event_type].present? ||
        active_state_filters.any?
    end

    # The "X unread" banner only makes sense if unread items can appear in the
    # current view at all: no state filter (the default shows unread+read)
    # OR 'unread' is explicitly active.
    def show_unread_banner?
      active_state_filters.empty? || active_state_filters.include?('unread')
    end

    private

    def compute!
      @active_state_filters = derive_active_state_filters
      @filtered = apply_state_filters(@scope)
      @view_mode = (@params[:view_mode].presence || 'grouped').to_s
      @total_count = @filtered.count
      @group_total = {}
      @group_unread = {}

      # Pagy 9: page size via :limit. NOT :items — that is not a Pagy 9
      # variable at all and would silently yield the default. It is not the URL
      # parameter name either, whatever this comment used to claim: the limit
      # extra sets that to :limit. See the closing note in
      # config/initializers/pagy.rb.
      if grouped?
        compute_grouped!
      else
        @notifications = @filtered.for_notification_center.recent
        @pagy, @notifications = @pagy_helper.send(:pagy, @notifications, limit: PAGE_SIZE)
      end
    end

    # Grouping = bundling per notifiable (ticket): ONE row per ticket,
    # represented by the NEWEST notification. Pagination runs at the ticket
    # level (PAGE_SIZE tickets/page), not at the notification level.
    # The rows are grouped by the date of their representative →
    # a ticket appears globally only ONCE, under the day of its last
    # activity. group_total/group_unread provide the bundle counts.
    def compute_grouped!
      # DISTINCT ON: one representative (newest) per notifiable. The subquery
      # returns only the IDs; ORDER BY must lead with the DISTINCT columns.
      rep_ids = @filtered.reorder(nil)
                         .select('DISTINCT ON (notifications.notifiable_type, notifications.notifiable_id) notifications.id')
                         .order(Arel.sql('notifications.notifiable_type, notifications.notifiable_id, notifications.created_at DESC'))

      rep_scope = Notification.where(id: rep_ids)
                              .for_notification_center
                              .order(created_at: :desc)

      @pagy, reps = @pagy_helper.send(:pagy, rep_scope, limit: PAGE_SIZE)

      # Counts over the ENTIRE filtered scope (not just this page), so that
      # the badge shows the real total count per ticket.
      @group_total = count_by_notifiable(@filtered)
      @group_unread = count_by_notifiable(@filtered.unread)

      @grouped_notifications = reps.group_by { |n| n.created_at.to_date }
      @notifications = reps
    end

    def derive_active_state_filters
      arr = Array(@params[:state_filters]).reject(&:blank?)
      arr << @params[:state] if arr.empty? && @params[:state].present?
      arr.uniq
    end

    def apply_state_filters(scope)
      if active_state_filters.any?
        allowed = []
        allowed += %w[queued sent delivered] if active_state_filters.include?('unread')
        allowed << 'read'     if active_state_filters.include?('read')
        allowed << 'archived' if active_state_filters.include?('archived')
        scope.where(state: allowed)
      else
        scope.where.not(state: Notification.states[:archived])
      end
    end

    # { [notifiable_type, notifiable_id] => count } over the scope.
    # reorder(nil) removes any ORDER BY columns that would otherwise have to go
    # into the GROUP BY clause (Postgres error).
    def count_by_notifiable(scope)
      scope.reorder(nil).group(:notifiable_type, :notifiable_id).count
    end
  end
end
