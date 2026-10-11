# frozen_string_literal: true

# The filter line of the billings list (P2 of
# doc/abrechnungen_filterzeile_und_tabelle_plan.md): the removal map, the
# address builder against the billings route, and the frame-dependent regions
# the list frame streams back. Same parts, same rules as the time list's
# (TimeSessionsHelper); the query arithmetic itself is FilterUrlHelper.
module TimeSessionGroupsHelper
  # What removing one filter changes in the address. nil clears a key. The
  # period clears its preset AND the hand-typed bounds at once - the time
  # list's rule: a preset and typed bounds must not survive each other.
  BILLING_FILTER_REMOVALS = {
    period: { 'date_range' => nil, 'start_date' => nil, 'end_date' => nil },
    status: { 'billing_status' => nil, 'billing_states' => nil },
    project: { 'project_id' => nil },
    search: { 'search' => nil }
  }.freeze

  # The two states of a billing on the wire. 'all' is not a value: it is the
  # absent parameter, both boxes on - the status row's default.
  BILLING_STATES = %w[unbilled billed].freeze

  # The page-load fallback address of a billings filter pill. The path comes
  # from the NAMED route (the Brakeman LinkToHref reasoning at
  # TimeSessionsHelper#time_list_filter_url); on click query_toggle rewrites
  # against the live address, exactly as on the time list.
  def billing_list_filter_url(changes = {})
    filter_url_for(organisation_time_session_groups_path(current_organisation), changes)
  end

  def billing_filter_removal_url(key)
    billing_list_filter_url(BILLING_FILTER_REMOVALS.fetch(key))
  end

  # A period preset's change: the period removal with the new range in it, so
  # choosing a preset clears hand-typed bounds. ONE owner for the href and the
  # owns declaration of every preset option.
  def billing_period_change(range_key)
    BILLING_FILTER_REMOVALS.fetch(:period).merge('date_range' => range_key)
  end

  # Whether anything narrows the billings list. Unlike the time list, the
  # defaults here ARE the neutral state ('all' status, 'all' period), so
  # "narrowed" and "the bare address would change something" are one question,
  # not two - which is why the reset can lead to the bare named route.
  # The two effective values are handed in by the caller (the view reads the
  # controller's ivars); params are read here because they are request state,
  # not controller state.
  def billing_filter_narrowed?(current_status, date_range)
    current_status != 'all' ||
      params[:project_id].present? ||
      params[:search].present? ||
      date_range != TimeSessions::ListPeriod::TABLE_DEFAULT
  end

  # The set a status toggle click produces, computed ONCE: the href (no-JS
  # fallback) and the owns declaration (live rewrite) both derive from it, the
  # time list's rule against the two drifting apart. The submitted parameter
  # wins over the effective default, so toggling off a default-on box works.
  def billing_state_toggle(value, current)
    submitted = Array(request.query_parameters['billing_states']).reject(&:blank?)
    active = request.query_parameters.key?('billing_states') ? submitted : Array(current)
    active.include?(value) ? active - [value] : active + [value]
  end

  def billing_state_owns_pairs(value, current)
    time_filter_owns_pairs('billing_states' => billing_state_toggle(value, current),
                           'billing_status' => nil)
  end

  # The status mark of a billing row (P3): a dot in the shared time tokens.
  # The colours belong to NeoTimeShareBarComponent (the one owner of the three
  # time-* tokens); this reads its constants instead of copying the classes.
  # A billing is billed or it is not, so the mark is always a single dot -
  # the component itself is about SHARES of minutes and would render an empty
  # track for a billing without sessions, which is the wrong statement here:
  # the state exists before the first booked minute.
  def billing_state_dot(billed)
    bucket = billed ? 'billed' : 'in_billing'
    tag.span(class: 'shrink-0 rounded-full border border-stroke/70 ' \
                    "#{NeoTimeShareBarComponent::DOT_SIZES.fetch(:row)} " \
                    "#{NeoTimeShareBarComponent::DOT_FILLS.fetch(bucket)}",
             aria: { hidden: true })
  end

  # The regions outside time_session_groups_list_frame whose content is a
  # reading of the very query that frame answers. _groups_list streams each of
  # them back with a frame answer - the time list's FRAME_DEPENDENT_REGIONS
  # pattern, for the same reason: without it a search narrows the list and the
  # figures beside it keep the values the page was opened with. Each partial
  # takes no locals, reads its own ivars and carries the id "billing_<region>".
  BILLING_FRAME_DEPENDENT_REGIONS = %w[status_row result_summary filter_reset].freeze
end
