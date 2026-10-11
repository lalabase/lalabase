# frozen_string_literal: true

module DashboardHelper
  # One rendered position in a row. `component` carries the widget when the viewer may see it;
  # `placeholder` marks a held slot for a widget the viewer currently lacks rights to (own config
  # only — see dashboard_row_slots). `units` drives the slot's proportional width.
  DashboardSlot = Struct.new(:component, :placeholder, :units, keyword_init: true)

  # Proportional column width per widget: flex-grow = units, flex-basis 0, so a row's widgets share
  # its width in proportion to their units and fill it without gaps. Only applies at lg (mobile
  # stacks via flex-col on the row). Literal strings so Tailwind's JIT (which scans
  # app/helpers/**/*.rb) emits these utilities.
  DASHBOARD_UNIT_FLEX = {
    1 => 'lg:flex-[1_1_0%]',
    2 => 'lg:flex-[2_1_0%]',
    3 => 'lg:flex-[3_1_0%]',
    4 => 'lg:flex-[4_1_0%]',
    5 => 'lg:flex-[5_1_0%]',
    6 => 'lg:flex-[6_1_0%]'
  }.freeze

  # The flex utility for a widget's column width. Falls back to 1 unit for an out-of-range value.
  def dashboard_unit_flex(units)
    DASHBOARD_UNIT_FLEX[units] || DASHBOARD_UNIT_FLEX[1]
  end

  # The display label for a widget key (i18n via the registry's label_key, humanized fallback).
  # Shared by _edit_slot and the widget_preview endpoint so both show the same label. `registry`
  # selects the surface catalogue (overview keys resolve only against the overview registry); it
  # defaults to the project dashboard so existing call sites stay untouched.
  def dashboard_widget_label(key, registry: Dashboards::LayoutEngine::WIDGET_REGISTRY)
    entry = registry[key]
    entry ? t(entry[:label_key], default: key.to_s.humanize) : key.to_s.humanize
  end

  # Builds the render plan for one row, permission-aware and branched by layout owner (§5/§15):
  # - viewer may see the widget               -> content slot
  # - may not, and it's the user's OWN config -> placeholder slot (slot held, layout NOT pruned;
  #                                              auto-refills when the right returns)
  # - may not, and it's an inherited default  -> omitted (filter_map drops it -> row reflows)
  # Unknown/undrawable widgets are dropped. NEVER mutates `row`; permission is a render-time
  # decision, never a persistence change.
  #
  # `dashboard_row_slots` (project) and `overview_row_slots` (org) are thin SURFACE bindings: each
  # injects its widget registry + its component context and delegates to the one shared
  # `render_row_slots` core, so the slot/placeholder/width logic lives exactly once (no per-surface
  # clone). The project signature is kept as-is so existing call sites stay untouched.
  def dashboard_row_slots(row, project:, user:, owned:)
    render_row_slots(row, registry: Dashboards::LayoutEngine::WIDGET_REGISTRY,
                          base_params: { project: project, user: user }, owned: owned)
  end

  # Overview surface binding (org-scoped). `briefing` is the single shared Dashboard::DailyBriefing
  # instance (built once per request, see briefings#show) so the converted widgets reuse its
  # memoised aggregates instead of each re-querying.
  def overview_row_slots(row, organisation:, user:, briefing:, owned:)
    render_row_slots(row, registry: Overview::WidgetRegistry::WIDGETS,
                          base_params: { organisation: organisation, user: user, briefing: briefing },
                          owned: owned)
  end

  # Shared core for both surfaces. `registry` selects the widget catalogue; `base_params` is the
  # component constructor context, forwarded verbatim to component_for_widget.
  def render_row_slots(row, registry:, base_params:, owned:)
    # First pass: the widgets this viewer actually renders (a dropped one must hand its width to the
    # others, so widths are computed over the SURVIVING slots, not the stored list).
    visible = Array(row['widgets']).filter_map do |widget|
      next if widget.blank?

      component = Dashboards::LayoutEngine.component_for_widget(widget, registry: registry, **base_params)
      next if component.nil?

      renderable = component.should_render?
      next unless renderable || owned

      { component: renderable ? component : nil, placeholder: !renderable,
        units: Dashboards::LayoutEngine.widget_units(widget, registry: registry),
        min: Dashboards::LayoutEngine.widget_min_units(widget, registry: registry) }
    end

    # Second pass: distribute to a full row (Σ = ROW_UNITS) so the rendered width matches the unit
    # proportion — same split-pane invariant the editor enforces.
    effective = Dashboards::LayoutEngine.distribute_row_units(visible.map { |s| s[:units] }, visible.map { |s| s[:min] })
    visible.each_with_index.map do |slot, i|
      DashboardSlot.new(component: slot[:component], placeholder: slot[:placeholder], units: effective[i])
    end
  end

  # The widget hashes of a row for the editor: each non-blank widget normalized to a hash (legacy
  # string entries included), in order. The editor renders one slot per entry plus a trailing "+".
  # `registry` selects the surface catalogue used to normalize legacy string entries; defaults to
  # the project dashboard so existing call sites stay untouched.
  def dashboard_edit_widgets(widgets, registry: Dashboards::LayoutEngine::WIDGET_REGISTRY)
    Array(widgets).filter_map do |raw|
      widget = raw.is_a?(String) ? Dashboards::LayoutEngine.normalize_widget(raw, registry: registry) : raw
      widget.presence
    end
  end

  # The form field-name prefix for one widget slot — the load-bearing serialization shape the
  # whole submit/reindex path depends on. Kept in one place so the settings partials read it from
  # here instead of re-typing the literal.
  # NOTE: dashboard_inline_edit_controller.js#reindex rebuilds this EXACT shape from DOM position
  # before submit (it cannot share this Ruby method). Change the shape here and you must change it
  # there too, or the server-rendered placeholder and the JS rewrite will silently disagree.
  def dashboard_widget_field_prefix(row_idx, slot_idx)
    "rows[#{row_idx}][widgets][#{slot_idx}]"
  end
end
