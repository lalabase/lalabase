# frozen_string_literal: true

class TimeSessionGroupFilterService
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :project_id, :string
  attribute :billing_status, :string
  attribute :start_date, :string
  attribute :end_date, :string
  attribute :search, :string

  def initialize(base_query:, **attributes)
    @base_query = base_query
    super(attributes)
  end

  def call
    query = @base_query
    query = apply_project_filter(query)
    query = apply_billing_status_filter(query)
    query = apply_date_range_filter(query)
    apply_search_filter(query)
  end

  private

  def apply_project_filter(query)
    return query if project_id.blank?

    with_time_sessions(query).where(time_sessions: { project_id: project_id })
  end

  def apply_billing_status_filter(query)
    case billing_status
    when 'billed' then query.billed
    when 'unbilled' then query.unbilled
    else query
    end
  end

  # The billing's own created_at, whole days inclusive (decision D-B of
  # doc/abrechnungen_filterzeile_und_tabelle_plan.md): the list column this
  # filter answers to is "erstellt". An earlier version filtered the member
  # sessions' occurred_on, but that semantics never shipped -- the service
  # existed without a caller.
  def apply_date_range_filter(query)
    from = parse_date(start_date)
    to = parse_date(end_date)
    return query if from.nil? && to.nil?

    scope = query
    scope = scope.where(created_at: from.beginning_of_day..) if from
    scope = scope.where(created_at: ..to.end_of_day) if to
    scope
  end

  def apply_search_filter(query)
    return query if search.blank?

    term = "%#{ActiveRecord::Base.sanitize_sql_like(search.strip)}%"

    query.where(
      'time_session_groups.name ILIKE :term OR time_session_groups.description ILIKE :term OR time_session_groups.invoice_number ILIKE :term',
      term: term
    )
  end

  def with_time_sessions(query)
    query.joins(:time_sessions).distinct
  end

  def parse_date(date_string)
    return nil if date_string.blank?

    Date.parse(date_string)
  rescue ArgumentError, TypeError
    Rails.logger.warn "TimeSessionGroupFilterService: Invalid date format: #{date_string}"
    nil
  end
end
