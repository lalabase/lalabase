# frozen_string_literal: true

# Overview widget: the viewer's own OPEN tickets across all their projects in the org. A personal
# work-list (assignee = the viewer), distinct from org_stats_cards' open_tickets_count (which counts
# everyone's open tickets). "Open" uses the project's System-Function-defined closed statuses
# (TicketAttributeDefinition), not a hardcoded "done".
#
# Configurable as a mini triage board: a checkbox picker (group_keys) selects which BUCKETS to show
# as labeled sections — "Alle offenen" plus the due-date buckets (overdue / due today / this week /
# next 7 days). Each bucket reuses the ONE due-date primitive Ticket.matching_due_preset, so a bucket
# means exactly the same here as in the FilterBar and SmartFolder. Default = just "all open" (the
# widget's original behavior, so existing overviews are unchanged).
#
# Because the buckets overlap (an overdue ticket is also "open"; a due-today ticket is also "due this
# week"), an opt-in `deduplicate` setting shows each ticket only ONCE — in its narrowest matching
# bucket (see DEDUP_PRIORITY) — so the sections read as a partition instead of repeating tickets.
#
# The buckets can be presented two ways (`display_mode`): as stacked sections (default, all visible at
# once for triage) or as switchable pills/tabs (one bucket at a time, matching the hours widget's pill
# navigation). The bucket computation is identical for both — only the template differs.
#
# Gated on tickets:read in any project (Current.area_access_anywhere?).
class Overview::MyOpenTicketsComponent < ViewComponent::Base
  # Selectable buckets in display order. 'all_open' is the full open list; the rest reuse the canonical
  # due-date presets (Ticket::DUE_DATE_PRESET_KEYS) so the bucket set never drifts from the filters.
  GROUP_KEYS = (%w[all_open] + Ticket::DUE_DATE_PRESET_KEYS).freeze
  # What an unconfigured widget shows: only the full open list (preserves the pre-picker behavior).
  DEFAULT_GROUP_KEYS = %w[all_open].freeze

  # Narrowest-first ownership order, used ONLY when de-duplication is on. The selected buckets overlap:
  # due_today ⊆ due_this_week ⊆ due_next_7_days (each is a subset of the next), overdue is date-disjoint
  # from those future buckets, and all_open is the catch-all that contains them all. When a ticket
  # matches several selected buckets we keep it in the NARROWEST one and drop it from the broader ones,
  # so it shows exactly once. This decides ownership only — sections still render in GROUP_KEYS order.
  DEDUP_PRIORITY = %w[due_today due_this_week due_next_7_days overdue all_open].freeze

  # How the selected buckets are presented (a per-widget display choice):
  #   'sections' — every bucket stacked as a labeled section, all visible at once (the default).
  #   'tabs'     — pills switch between buckets, one visible at a time (matches the hours widget's pill
  #                navigation; switching is client-side via tabs_controller).
  DISPLAY_MODES = %w[sections tabs].freeze
  DEFAULT_DISPLAY_MODE = 'sections'

  def initialize(organisation:, user:, briefing:, limit: nil, group_keys: nil, deduplicate: false,
                 display_mode: nil)
    @organisation = organisation
    @user = user
    # Part of the overview base_params contract (every widget receives it); this widget queries
    # tickets directly and does not read it, but stores it like the other overview components.
    @briefing = briefing
    @limit = limit
    @group_keys = group_keys
    # Boolean cast: the stored setting arrives as true / nil (see the registry parse); a checkbox value
    # like "1"/"0" is also handled, so the picker and a programmatic caller behave identically.
    @deduplicate = ActiveModel::Type::Boolean.new.cast(deduplicate)
    # Unknown/forged values fall back to the default mode (sections).
    @display_mode = DISPLAY_MODES.include?(display_mode.to_s) ? display_mode.to_s : DEFAULT_DISPLAY_MODE
  end

  def should_render?
    Current.area_access_anywhere?(user, organisation, :tickets, :read)
  end

  # The selected buckets, each as { key:, tickets: }, in display (GROUP_KEYS) order. Rendered as
  # labeled sections (see the template).
  def groups
    @groups ||= visible_group_keys.map { |key| { key: key, tickets: tickets_by_key.fetch(key, []) } }
  end

  # True when more than one bucket is selected. In the SECTIONS view this decides whether each bucket
  # gets a header (with a single bucket it reads as one plain list — the original look). NB: this is
  # about the NUMBER OF GROUPS, not the display mode — for sections-vs-pills see #tabs?.
  def multiple_groups?
    groups.size > 1
  end

  # True when no selected bucket has any ticket — drives the single widget-level empty state.
  def all_empty?
    groups.all? { |group| group[:tickets].empty? }
  end

  # True when the buckets are presented as switchable pills (one visible at a time) rather than stacked
  # sections. See DISPLAY_MODES.
  def tabs?
    @display_mode == 'tabs'
  end

  # The translated label for a bucket. Centralised so the i18n key shape lives in ONE place (the
  # template renders it for both the pills and the section headers).
  def group_label(key)
    t("overview.my_open_tickets.group_#{key}")
  end

  # The pill shown on load in tabs mode: the first selected bucket that has tickets, else the first
  # selected bucket — so the widget never opens on an empty panel when a non-empty one exists.
  def default_active_key
    @default_active_key ||= (groups.find { |group| group[:tickets].any? } || groups.first)&.fetch(:key)
  end

  private

  attr_reader :organisation, :user

  # nil group_keys (never configured) -> default (all_open only); a configured list -> that subset in
  # canonical order, ignoring forged/unknown keys.
  def visible_group_keys
    @group_keys.nil? ? DEFAULT_GROUP_KEYS : (GROUP_KEYS & Array(@group_keys).map(&:to_s))
  end

  # key => the tickets to display for that bucket. Two modes:
  #   independent (default) — each bucket is queried + limited on its own; a ticket can appear in
  #     several sections (overdue ones also show under all_open, etc.).
  #   deduplicated — a ticket is shown in exactly its NARROWEST selected bucket (see DEDUP_PRIORITY).
  def tickets_by_key
    @tickets_by_key ||= deduplicate? ? deduplicated_tickets : independent_tickets
  end

  # Each bucket independent, capped at the limit. `first(n)` issues a SQL LIMIT on a relation (and is a
  # plain take on an array), so the query stays cheap.
  def independent_tickets
    visible_group_keys.index_with { |key| ordered_scope(key).first(effective_limit) }
  end

  # Fill buckets narrowest-first; a ticket is claimed by the first (narrowest) bucket that contains it
  # and skipped everywhere broader. We load each bucket WITHOUT a SQL limit here (the limit is applied
  # per bucket AFTER claiming) so a narrower bucket can never starve a broader one of rows it should
  # still show — acceptable because this is the viewer's own open assigned tickets (a bounded set) and
  # de-duplication is opt-in.
  def deduplicated_tickets
    seen = []
    claimed = visible_group_keys.index_with { [] }
    fill_order(visible_group_keys).each do |key|
      ordered_scope(key).each do |ticket|
        next if seen.include?(ticket.id)

        seen << ticket.id
        claimed[key] << ticket
      end
    end
    claimed.transform_values { |tickets| tickets.first(effective_limit) }
  end

  # The bucket's tickets as an ordered relation, no limit. all_open = most recently touched first; the
  # due-date buckets = soonest due first.
  def ordered_scope(key)
    if key == 'all_open'
      base_scope.order(updated_at: :desc)
    else
      base_scope.matching_due_preset(key).order_by_due_date
    end
  end

  # The selected keys ordered narrowest-first for de-dup ownership. A key not in DEDUP_PRIORITY (should
  # never happen) sorts last rather than crashing.
  def fill_order(keys)
    keys.sort_by { |key| DEDUP_PRIORITY.index(key) || DEDUP_PRIORITY.length }
  end

  def deduplicate?
    # In tabs mode only one bucket is ever visible, so de-duplication across buckets is meaningless —
    # each pill reads as an independent filter with its own raw count. Force it off there.
    @deduplicate && !tabs?
  end

  # The viewer's assigned, OPEN tickets across their projects — without order/limit, so each bucket can
  # layer its own filter + ordering on top. Built once and shared across buckets.
  def base_scope
    @base_scope ||= if project_ids.empty?
                      Ticket.none
                    else
                      TicketPolicy::Scope.new(user, Ticket.where(project_id: project_ids))
                                         .resolve
                                         .assigned_to(user)
                                         .excluding_status_values(inactive_status_values)
                                         .includes(:project)
                    end
  end

  # Reuses the shared sanitise-or-default helper so the limit behaves exactly like the other list
  # widgets (whitelisted values, default of DEFAULT_ITEM_LIMIT).
  def effective_limit
    Dashboards::LayoutEngine.effective_item_limit('limit' => @limit)
  end

  # "Open" = active work: not closed AND not backlog (the project dashboard's open-ticket definition).
  # #126 generalised excluding_closed -> excluding_status_values and added the backlog dimension.
  def inactive_status_values
    TicketAttributeDefinition.closed_status_values_for(project_ids) |
      TicketAttributeDefinition.backlog_status_values_for(project_ids)
  end

  def project_ids
    @project_ids ||= ProjectPolicy::Scope.new(user, organisation.projects.active).resolve.pluck(:id)
  end
end
