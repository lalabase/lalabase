# frozen_string_literal: true

module Tickets
  # Shared ticket-LIST query shaping: filtering, ordering, pagination and the
  # total count. Used by BOTH Api::V1::TicketsController#index and the MCP
  # list_tickets tool, so the two surfaces apply identical semantics — the
  # query-side counterpart to the shared Tickets::Serializer (D4). Before this,
  # the same filter SQL lived in both places and could silently drift.
  #
  # Reads from a plain params/args object via #[], so neither caller's request
  # type leaks in: ActionController::Parameters (controller) and a symbol-keyed
  # Hash (tool) both support indifferent key access for the keys we read. The
  # caller still owns authorization scoping (policy_scope) and the includes it
  # needs — Filter only shapes the query it is handed.
  class Filter
    MAX_PER_PAGE = 100
    DEFAULT_PER_PAGE = 25

    # @param params [#[]] reads status, assignee ("me" or a user id), tag, from,
    #   to, q, page, per_page. Any absent key is a no-op.
    # @param current_user [User] resolves assignee == "me".
    def initialize(params, current_user:)
      @params = params
      @current_user = current_user
    end

    # status + assignee + tag + date-range, each a no-op when its key is absent.
    def filtered(scope)
      scope = by_status(scope)
      scope = by_assignee(scope)
      scope = by_tag(scope)
      by_date_range(scope)
    end

    # Full-text search preserves pg_search's rank order; otherwise newest-updated
    # first — the order a "what changed lately" list wants.
    def ordered(scope)
      if @params[:q].present?
        scope.text_search(@params[:q].to_s)
      else
        scope.order(updated_at: :desc)
      end
    end

    # A tag filter groups by ticket id, so .count returns a per-id Hash — its size
    # is the distinct-ticket total. Ungrouped scopes return the integer directly.
    # (Centralising this also fixes the controller, which previously returned the
    # raw Hash as `total` when a tag filter was active.)
    def total(scope)
      counted = scope.count
      counted.is_a?(Hash) ? counted.size : counted
    end

    def page
      [@params[:page].to_i, 1].max
    end

    def per_page
      raw = @params[:per_page].to_i
      return DEFAULT_PER_PAGE if raw <= 0

      [raw, MAX_PER_PAGE].min
    end

    def paginate(scope)
      scope.limit(per_page).offset((page - 1) * per_page)
    end

    private

    def by_status(scope)
      return scope if @params[:status].blank?

      values = Array(@params[:status]).map { |s| s.to_s.downcase }
      scope.where("LOWER(custom_attributes->>'status') IN (?)", values)
    end

    def by_assignee(scope)
      return scope if @params[:assignee].blank?

      user_id = @params[:assignee].to_s == 'me' ? @current_user.id : @params[:assignee]
      scope.joins(:ticket_assignments).where(ticket_assignments: { user_id: user_id })
    end

    # AND semantics across multiple tags: GROUP + HAVING count = number of tags.
    def by_tag(scope)
      return scope if @params[:tag].blank?

      names = Array(@params[:tag]).map { |n| n.to_s.downcase.strip }.reject(&:blank?)
      return scope if names.empty?

      scope.joins(taggings: :tag)
           .where(taggings: { taggable_type: 'Ticket' })
           .where(tags: { name: names })
           .group('tickets.id')
           .having('COUNT(DISTINCT tags.id) = ?', names.size)
    end

    # An unparseable from/to is ignored rather than erroring. .to_s guards against
    # a non-string value (e.g. a tampered array param) raising TypeError, which the
    # ArgumentError rescue would not catch.
    def by_date_range(scope)
      scope = scope.where('tickets.updated_at >= ?', Date.parse(@params[:from].to_s)) if @params[:from].present?
      scope = scope.where('tickets.updated_at <= ?', Date.parse(@params[:to].to_s).end_of_day) if @params[:to].present?
      scope
    rescue ArgumentError
      scope
    end
  end
end
