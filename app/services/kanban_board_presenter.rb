# frozen_string_literal: true

# The board's columns from a filtered ticket scope: one per configured value
# of the grouping attribute, plus "Nicht zugeordnet" for tickets without one.
# Two caps keep the page small: MAX_TOTAL_TICKETS loaded in all, then
# TICKETS_PER_COLUMN cards per column. The open ticket (`selected:`) gets its
# card across both caps, from the same scope (D3 of
# doc/kanban_ticket_als_bahn_plan.md); a ticket the scope excludes gets none.
#
# Entry point: columns
class KanbanBoardPresenter
  TICKETS_PER_COLUMN = 20
  MAX_TOTAL_TICKETS = 500

  # Status functions whose tickets are "not active work right now". When the board
  # is grouped by status, these sort LAST so the MAX_TOTAL_TICKETS cap drops a big
  # backlog (or pile of closed tickets) first instead of starving active columns.
  INACTIVE_STATUS_FUNCTIONS = [
    SystemFunctions::Registry::IS_BACKLOG,
    SystemFunctions::Registry::IS_COMPLETED,
    SystemFunctions::Registry::IS_CLOSED
  ].freeze

  def initialize(tickets_scope, kanban_attribute, selected: nil)
    @tickets_scope = tickets_scope
    @kanban_attribute = kanban_attribute
    @selected = selected
  end

  attr_reader :kanban_attribute, :total_in_scope

  def columns
    @columns ||= build_columns
  end

  def capped?
    @capped
  end

  private

  def build_columns
    # Count the unordered scope: total_in_scope is "how many tickets exist", independent
    # of the cap ordering (and it avoids shipping the dead ORDER BY in a COUNT).
    @total_in_scope = @tickets_scope.count
    scope = order_inactive_last(@tickets_scope)
    @capped = @total_in_scope > MAX_TOTAL_TICKETS

    loaded = scope.limit(MAX_TOTAL_TICKETS).includes(:assignees, :tags).to_a
    grouped = loaded.group_by { |ticket| value_of(ticket) }
    beyond_cap = selected_beyond_cap(loaded)

    columns = @kanban_attribute.allowed_values.map do |option|
      value = option['value']
      column_for(value: value, tickets: grouped[value] || [], beyond_cap: beyond_cap,
                 label: @kanban_attribute.display_value(value),
                 color: TicketAttributeDefinition.safe_option_color(option['color']),
                 system_functions: option['system_functions'] || [])
    end

    unassigned = column_for(value: nil, tickets: grouped[nil] || [], beyond_cap: beyond_cap,
                            label: I18n.t('kanban.unassigned'), system_functions: [])
    columns.unshift(unassigned) if show_unassigned_column?(unassigned)
    columns
  end

  # The cards of one column: the first TICKETS_PER_COLUMN, plus the open
  # ticket's card when it is in this column but beyond a cap, appended last and
  # never twice. hidden_count is what is NOT rendered (total minus the cards),
  # so an appended card moves both numbers and the "+n weitere" note stays
  # right; a card from beyond MAX_TOTAL_TICKETS adds one to the total as well,
  # it was not in the loaded group.
  def column_for(value:, tickets:, beyond_cap:, **attrs)
    rendered = tickets.first(TICKETS_PER_COLUMN)
    total = tickets.size
    if @selected && rendered.none? { |ticket| ticket.id == @selected.id }
      appended = tickets.find { |ticket| ticket.id == @selected.id }
      if appended.nil? && beyond_cap && value_of(beyond_cap) == value
        appended = beyond_cap
        total += 1
      end
      rendered += [appended] if appended
    end
    hidden = total - rendered.size
    attrs.merge(value: value, tickets: rendered, total_count: total, hidden_count: hidden, has_more: hidden.positive?)
  end

  # The open ticket when it is in the view but not among the loaded tickets:
  # fetched from the same filtered, authorised scope, so a ticket the view's
  # filters exclude stays without a card, exactly as the list behaves.
  def selected_beyond_cap(loaded)
    return nil if @selected.nil? || loaded.any? { |ticket| ticket.id == @selected.id }

    @tickets_scope.includes(:assignees, :tags).find_by(id: @selected.id)
  end

  # "Nicht zugeordnet" is a state too (rule 4, D6): the column stands even
  # empty, so a card can always be dragged there to clear its value. The one
  # exception is an attribute that is strictly required, which gets no EMPTY
  # column: what it holds anyway (legacy values, the open ticket loaded in)
  # shows, and the write path refuses a new clear (Tickets::Changes::SetSelect).
  def show_unassigned_column?(column)
    column[:tickets].any? || !@kanban_attribute.strictly_required?
  end

  def value_of(ticket)
    ticket.get_custom_attribute(@kanban_attribute.name).presence
  end

  # Sorts inactive-status tickets (backlog/done) to the end so the cap drops them first.
  # No-op when the grouping attribute carries no inactive-tagged options (e.g. a board
  # grouped by priority) — then there is nothing to deprioritize.
  # The original order is preserved as the secondary sort (within-column ordering).
  def order_inactive_last(scope)
    values = inactive_status_values
    return scope if values.empty?

    # Compare against the GROUPING attribute's own JSONB key, not a hardcoded 'status':
    # the board can be grouped by any select attribute, and inactive_status_values is
    # derived from that same attribute. @kanban_attribute.name is a format-validated
    # identifier (/\A[a-z][a-z0-9_]*\z/), so it is safe to interpolate as the JSONB key.
    column = "custom_attributes->>'#{@kanban_attribute.name}'"
    case_sql = ActiveRecord::Base.sanitize_sql_array(
      ["CASE WHEN LOWER(#{column}) IN (?) THEN 1 ELSE 0 END", values]
    )
    reordered = scope.reorder(Arel.sql(case_sql))
    original_order = scope.order_values
    original_order.any? ? reordered.order(*original_order) : reordered
  end

  def inactive_status_values
    @inactive_status_values ||= @kanban_attribute.allowed_values
                                                 .select { |opt| (opt['system_functions'] || []).intersect?(INACTIVE_STATUS_FUNCTIONS) }
                                                 .map { |opt| opt['value'].to_s.downcase }
  end
end
