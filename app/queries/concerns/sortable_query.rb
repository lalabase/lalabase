# frozen_string_literal: true

# Sortable concern for query objects
# Provides standardized sorting functionality for queries
module SortableQuery
  extend ActiveSupport::Concern

  VALID_SORT_COLUMNS = {
    'title' => 'tickets.title',
    'number' => 'tickets.number',
    'created_at' => 'tickets.created_at',
    'updated_at' => 'tickets.updated_at',
    'search_rank' => 'search_rank' # For sorting by relevance
  }.freeze
  # NOTE: status/priority are deliberately absent here. They live in JSONB
  # custom_attributes (the ticket_statuses/ticket_priorities tables were dropped) and
  # sort by their configured option order — handled explicitly in apply_sorting.

  VALID_DIRECTIONS = %w[asc desc].freeze

  def apply_sorting(query)
    # On search: sort by relevance by default
    if search_term.present? && @params[:sort].blank?
      return query # Already sorted by search_rank
    end

    # Custom-attribute sort: select fields (status/priority) by configured option order,
    # date fields (due_date) chronologically. Dispatch lives in Ticket.custom_attribute_sort_sql
    # so the date-vs-select branch is shared with the controller path and cannot drift.
    attr_name = Ticket.sortable_custom_attribute(raw_sort_column)
    return query.reorder(Arel.sql(Ticket.custom_attribute_sort_sql(attr_name, @project, sort_direction))) if attr_name

    column = sort_column
    direction = sort_direction

    return query.order(default_sort) unless column && direction

    # Special handling for search_rank (must be in the SELECT)
    return query.order(default_sort) if column == 'search_rank' && !query.to_sql.include?('search_rank')

    query.order("#{column} #{direction} NULLS LAST")
  end

  private

  # Raw sort column from params (before whitelist mapping). Supports both the Hash
  # format { column:, direction: } and a plain string.
  def raw_sort_column
    if @params[:sort].is_a?(Hash) || @params[:sort].is_a?(ActionController::Parameters)
      @params[:sort][:column]&.to_s
    else
      @params[:sort]&.to_s
    end
  end

  def sort_column
    VALID_SORT_COLUMNS[raw_sort_column]
  end

  def sort_direction
    # Support both Hash format and separate :direction param
    direction = if @params[:sort].is_a?(Hash) || @params[:sort].is_a?(ActionController::Parameters)
                  @params[:sort][:direction]&.to_s&.downcase
                else
                  @params[:direction]&.to_s&.downcase
                end
    VALID_DIRECTIONS.include?(direction) ? direction : 'desc'
  end

  def default_sort
    'tickets.created_at DESC'
  end
end
