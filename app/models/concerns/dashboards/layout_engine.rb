# frozen_string_literal: true

# Module for dashboard layout configuration.
# Provides the widget registry, row types, and layout resolution.
# Used both as a concern included in DashboardConfiguration and
# called directly via Dashboards::LayoutEngine.method().
module Dashboards
  module LayoutEngine
    extend ActiveSupport::Concern

    # A row is a 6-unit horizontal track. Each widget occupies a number of units; widths within a
    # row are proportional to units (flex-grow), so Σ units ≤ ROW_UNITS keeps every widget at or
    # above its registered minimum. Replaces the old fixed row types (full/half/quarter).
    ROW_UNITS = 6

    # List widgets (recent_tickets / recent_notes / smart_folder_tickets) let the user pick how many
    # rows they show. Fixed set so the editor is a simple dropdown and a forged value is rejectable.
    LIST_LIMIT_OPTIONS = [5, 10, 15, 20, 25].freeze
    DEFAULT_ITEM_LIMIT = 5
    # recent_tickets shows more rows in a grouped display (preserves today's hardcoded behaviour
    # when no explicit limit is stored).
    GROUPED_TICKETS_LIMIT = 20

    WIDGET_REGISTRY = {
      'stats_cards' => {
        label_key: 'dashboard.widgets.stats_cards',
        component: 'Dashboard::StatsCardsComponent',
        units: 1, # minimum width in 1/6 of a row (stat cards wrap internally)
        permission: nil,
        extra_params: ->(data) { { card_settings: data['cards'] } },
        normalize: ->(param) { { 'cards' => param.split(',').map { |k| { 'key' => k } } } }
      },
      'recent_tickets' => {
        label_key: 'dashboard.widgets.recent_tickets',
        component: 'Dashboard::RecentTicketsComponent',
        units: 2, # minimum width in 1/6 of a row
        permission: { area: :tickets, action: :read },
        extra_params: ->(data) { { display: data['display'], period: data['period'], limit: data['limit'] } }
      },
      'recent_notes' => {
        label_key: 'dashboard.widgets.recent_notes',
        component: 'Dashboard::RecentNotesComponent',
        units: 2, # minimum width in 1/6 of a row
        permission: { area: :notes, action: :read },
        extra_params: ->(data) { { limit: data['limit'] } }
      },
      'team_members' => {
        label_key: 'dashboard.widgets.team_members',
        component: 'Dashboard::TeamMembersComponent',
        units: 2, # minimum width in 1/6 of a row
        permission: { area: :members, action: :read }
      },
      'notifications' => {
        label_key: 'dashboard.widgets.notifications',
        component: 'Dashboard::NotificationsComponent',
        units: 2, # minimum width in 1/6 of a row
        permission: nil
      },
      'time_tracking' => {
        label_key: 'dashboard.widgets.time_tracking',
        component: 'Dashboard::TimeTrackingComponent',
        units: 2, # minimum width in 1/6 of a row
        permission: { area: :time_sessions, action: :read }
      },
      'smart_folder_tickets' => {
        label_key: 'dashboard.widgets.smart_folder_tickets',
        component: 'Dashboard::SmartFolderTicketsComponent',
        units: 2, # minimum width in 1/6 of a row
        permission: { area: :tickets, action: :read },
        extra_params: ->(data) { { smart_folder_id: data['folder_id'], limit: data['limit'] } },
        normalize: ->(param) { { 'folder_id' => param } }
      },
      'project_info' => {
        label_key: 'dashboard.widgets.project_info',
        component: 'Dashboard::ProjectInfoComponent',
        units: 2, # minimum width in 1/6 of a row
        permission: nil
      }
    }.freeze

    # System default layout: identical to the previous fixed dashboard
    SYSTEM_DEFAULT_LAYOUT = [
      { 'widgets' => ['stats_cards'] },
      { 'widgets' => ['project_info'] },
      { 'widgets' => %w[recent_tickets recent_notes] },
      { 'widgets' => ['team_members'] }
    ].freeze

    # Result of layout resolution: the layout plus whether it is the user's OWN config.
    # `owned` drives the permission-aware render (§5/§15): own config keeps a placeholder in
    # the slot when a right is missing (auto-refills later); an inherited default is filtered
    # per viewer instead. Never used to mutate the stored layout.
    LayoutResolution = Struct.new(:layout, :owned)

    # Module-level methods (callable as Dashboards::LayoutEngine.method)
    class << self
      # Resolves the dashboard layout: user config -> project default -> system default.
      # Each level is checked independently, so that an empty layout correctly falls through.
      def resolve_layout(user, project)
        resolve_layout_with_source(user, project).layout
      end

      # Like resolve_layout, but also reports whether the layout is the user's OWN config
      # (owned: true) vs an inherited project/system default (owned: false). See LayoutResolution.
      # Thin project-surface binding over the generic #resolve_cascade.
      def resolve_layout_with_source(user, project)
        resolve_cascade(config_class: DashboardConfiguration, scope: { project: project },
                        user: user, system_default: SYSTEM_DEFAULT_LAYOUT)
      end

      # The generic layout cascade, shared by every dashboard-style surface (project + org overview):
      # the viewer's OWN config (owned: true) -> the surface DEFAULT (user_id NULL, owned: false) ->
      # the system default (owned: false). Each level is checked independently so an empty STORED
      # layout correctly falls through to the next (a saved [] means "no preference", not "blank
      # dashboard"). `scope` is the surface key the config is found by ({ project: } or
      # { organisation: }); it is merged with the viewer (or nil) to locate the personal/default rows.
      # Kept generic so the org overview reuses the EXACT cascade instead of re-implementing it.
      def resolve_cascade(config_class:, scope:, user:, system_default:)
        own = config_class.find_by(scope.merge(user: user))
        return LayoutResolution.new(own.layout, true) if own&.layout.present?

        default = config_class.find_by(scope.merge(user: nil))
        return LayoutResolution.new(default.layout, false) if default&.layout.present?

        LayoutResolution.new(system_default, false)
      end

      # Project-surface binding (unchanged signature): the widgets a viewer may add to a PROJECT
      # dashboard, filtered by the single-project ProjectPolicy. Delegates to the generic filter.
      def available_widgets_for(user, project)
        policy = Current.project_policy(user, project)
        available_widgets_in(registry: WIDGET_REGISTRY) { |area, action| policy.area_access?(area, action) }
      end

      # The registry entries whose permission the viewer satisfies. `granted` is the surface's
      # permission check, called with (area, action) — single-project ProjectPolicy for the project
      # dashboard, org "any project" (Current.area_access_anywhere?) for the overview. One filter,
      # bound per surface (no duplicated select/permission logic).
      def available_widgets_in(registry:, &granted)
        registry.select do |_key, config|
          perm = config[:permission]
          perm.nil? || granted.call(perm[:area], perm[:action])
        end
      end

      # True when a widget needs a permission the viewer lacks — it has a registered permission but is
      # absent from the permission-filtered `available_widgets` set. Drives the "no access" placeholder.
      # Shared by _edit_slot (inline render) and the widget_preview endpoint (which has no slot context)
      # so both decide access identically. `registry` defaults to the project surface (backward-compatible).
      def widget_no_access?(key, available_widgets, registry: WIDGET_REGISTRY)
        entry = registry[key]
        entry.present? && entry[:permission].present? && !available_widgets.key?(key)
      end

      # Builds one widget hash from its submitted params (key + width units + per-key settings). Shared
      # by the layout save (parse_layout_from_params) and the live widget_preview so the preview can
      # never parse settings differently than the save does. `w` is the per-widget params
      # (ActionController::Parameters or a symbol-keyed Hash). Returns nil for a blank/keyless slot.
      def build_widget(w, registry: WIDGET_REGISTRY)
        # The widget params come straight from the request; a forged/garbled `rows[i][widgets]` can be
        # a String/Integer instead of the expected per-widget hash. Reading `w[:key]` on those raises
        # TypeError and 500s the save/preview. Skip anything that is not a key/value param object.
        return nil unless w.is_a?(ActionController::Parameters) || w.is_a?(Hash)

        widget_key = w[:key].presence
        return nil if widget_key.blank?

        widget = { 'key' => widget_key }

        # Width per widget, in 1/6-of-a-row units. Only a value ABOVE the type minimum is stored — the
        # minimum is the default, so persisting it would be noise. The model enforces the upper bound.
        units = w[:units].to_i
        units_min = registry.dig(widget_key, :units) || 1
        widget['units'] = units if units > units_min

        # Per-widget settings parsing. A registry MAY declare a `parse:` lambda per entry (the overview
        # surface does — D3): when present it owns the settings shape and returns the keys to merge.
        # The PROJECT registry has no `parse:`, so it keeps the legacy `case` below byte-identical (its
        # widgets are deliberately NOT migrated to parse: here, so the project save path is unchanged).
        # Exactly one of the two runs per widget.
        if (parser = registry.dig(widget_key, :parse))
          widget.merge!(parser.call(w) || {})
        else
          # One branch per settings-bearing widget — the same set as WIDGET_REGISTRY's :extra_params
          # keys, _edit_slot's has_settings gate, and _widget_settings' case. A widget whose fields are
          # rendered but not parsed here loses its settings silently; keep these in sync.
          case widget_key
          when 'smart_folder_tickets'
            widget['folder_id'] = w[:folder_id] if w[:folder_id].present?
            assign_item_limit(widget, w)
          when 'stats_cards'
            cards = parse_card_settings(w)
            widget['cards'] = cards if cards.any?
          when 'recent_tickets'
            widget['display'] = w[:display] if w[:display].present?
            widget['period'] = w[:period] if w[:period].present?
            assign_item_limit(widget, w)
          when 'recent_notes'
            assign_item_limit(widget, w)
          end
        end

        widget
      end

      # Stores a whitelisted per-widget item count for list widgets when one is submitted; an absent or
      # forged value simply keeps the component's own default (re-rejected by the model if forged).
      def assign_item_limit(widget, w)
        limit = sanitized_item_limit(w[:limit])
        widget['limit'] = limit if limit
      end

      # Normalizes a stats_cards widget's submitted card params into [{key, period?, scope?}, …],
      # dropping blank card keys. Called by build_widget; split out so the stats-card shape lives in
      # one place.
      def parse_card_settings(widget_params)
        card_keys = Array(widget_params[:card_keys]).reject(&:blank?)
        # card_settings is indexed by card key below; a forged `card_settings[]=x` arrives as an Array,
        # and Array["tickets"] raises TypeError. Only treat a real key/value object as settings.
        card_settings = widget_params[:card_settings]
        card_settings = {} unless card_settings.is_a?(ActionController::Parameters) || card_settings.is_a?(Hash)

        card_keys.map do |key|
          card = { 'key' => key }
          settings = card_settings[key]
          if settings
            card['period'] = settings[:period] if settings[:period].present?
            card['scope'] = settings[:scope] if settings[:scope].present?
          end
          card
        end
      end

      # The number of units a widget occupies in its row. Defaults to the widget type's registered
      # minimum (WIDGET_REGISTRY[:units]); a stored positive integer overrides it, clamped to
      # [min, ROW_UNITS]. `span` is read as a fallback so pre-existing layouts (which stored width as
      # `span`) keep their widths. One definition shared by Σ-units validation and the render helpers
      # so they can never disagree on what an absent/invalid width means.
      # `registry` defaults to the project WIDGET_REGISTRY so existing call sites are unchanged;
      # the overview surface passes Overview::WidgetRegistry::WIDGETS. One shared implementation,
      # bound per surface by its registry (no duplication).
      def widget_units(widget, registry: WIDGET_REGISTRY)
        min = registry.dig(base_widget_key(widget), :units) || 1

        stored = widget.is_a?(Hash) ? (widget['units'] || widget['span']) : nil
        units = stored.is_a?(Integer) && stored.positive? ? stored : min
        units.clamp(min, ROW_UNITS)
      end

      # The widget key from a hash ('key') or a legacy string (base of 'key:param'); nil for anything
      # else (a malformed numeric/array entry). Kept in one place so the width helpers never call #dig
      # on a non-Hash and crash on a malformed layout — such entries are rejected by the model
      # validation, but the width math must stay total.
      def base_widget_key(widget)
        return parse_widget_key(widget).first if widget.is_a?(String)

        widget['key'] if widget.is_a?(Hash)
      end

      # The registered MINIMUM width (in 1/6-of-a-row units) for a widget hash or legacy string. The
      # floor every width control and the unit distribution clamp to.
      def widget_min_units(widget, registry: WIDGET_REGISTRY)
        registry.dig(base_widget_key(widget), :units) || 1
      end

      # Distributes a row's widget widths so they sum to EXACTLY ROW_UNITS — the split-pane invariant
      # that keeps the rendered width equal to the unit proportion (no hidden free space). Under-full
      # rows grow round-robin from the left; over-full rows shrink from the right toward each minimum.
      # `base_units`/`mins` are parallel arrays, one entry per (visible) widget in row order. Mirrors
      # the JS normalizeRow so the server render and the inline editor produce identical widths.
      def distribute_row_units(base_units, mins)
        units = base_units.map(&:to_i)
        return units if units.empty?

        if units.sum < ROW_UNITS
          i = 0
          while units.sum < ROW_UNITS
            units[i % units.length] += 1
            i += 1
          end
        elsif units.sum > ROW_UNITS
          (units.length - 1).downto(0) do |j|
            break if units.sum <= ROW_UNITS

            take = [units[j] - mins[j].to_i, units.sum - ROW_UNITS].min
            units[j] -= take if take.positive?
          end
        end
        units
      end

      # The configured row count for a list widget, or nil when unset/invalid (caller falls back to
      # its own default). Accepts the raw JSONB value (Integer) or a String (form param) and only
      # accepts a whitelisted option, so the editor, the parser, the model and the components agree.
      def sanitized_item_limit(raw)
        raw = Integer(raw, exception: false) if raw.is_a?(String)
        raw if raw.is_a?(Integer) && LIST_LIMIT_OPTIONS.include?(raw)
      end

      # The effective row count for a list widget given its stored data: explicit limit if valid,
      # else the widget's default. One definition shared by the components' fallback AND the editor's
      # pre-selected dropdown value, so a no-op save preserves today's behaviour and the two
      # never disagree.
      def effective_item_limit(widget_data)
        data = widget_data.is_a?(Hash) ? widget_data : { 'key' => widget_data }
        sanitized_item_limit(data['limit']) || default_item_limit(data)
      end

      # Default row count when no explicit limit is stored: grouped recent_tickets shows more.
      def default_item_limit(widget_data)
        grouped = widget_data['key'] == 'recent_tickets' && widget_data['display'].to_s.start_with?('grouped_')
        grouped ? GROUPED_TICKETS_LIMIT : DEFAULT_ITEM_LIMIT
      end

      # Parses a widget key into a base key and an optional parameter
      # 'smart_folder_tickets:abc-123' -> ['smart_folder_tickets', 'abc-123']
      # 'recent_tickets' -> ['recent_tickets', nil]
      def parse_widget_key(key)
        return [nil, nil] if key.blank?

        parts = key.to_s.split(':', 2)
        base_key = parts[0]
        param = parts[1].presence

        [base_key, param]
      end

      # Converts a legacy string into a widget hash, using :normalize from the registry for
      # widget-specific parameters. `registry` defaults to the project surface; the overview passes
      # its own (same backward-compatible default as the width helpers).
      def normalize_widget(str, registry: WIDGET_REGISTRY)
        base_key, param = parse_widget_key(str)
        return {} unless base_key

        result = { 'key' => base_key }
        normalizer = registry.dig(base_key, :normalize)
        result.merge!(normalizer.call(param)) if normalizer && param
        result
      end

      # Creates a component instance for a widget key or widget hash. `registry` selects the surface's
      # widget catalogue; `base_params` is the surface's constructor context, forwarded verbatim to
      # the component — { project:, user: } for the project dashboard, { organisation:, user:,
      # briefing: } for the overview. Using a keyword splat keeps existing project call sites
      # (component_for_widget(widget, project:, user:)) unchanged while letting the overview pass its
      # own context. Returns nil if the widget is unknown or its component class is missing.
      def component_for_widget(widget_data, registry: WIDGET_REGISTRY, **base_params)
        widget_data = normalize_widget(widget_data, registry: registry) if widget_data.is_a?(String)
        return nil unless widget_data.is_a?(Hash)

        key = widget_data['key']
        return nil if key.blank?

        registry_entry = registry[key]
        return nil unless registry_entry

        # D3: only a MISSING component class is swallowed (config drift -> skip widget). The .new
        # is OUTSIDE the rescue, so a bug inside a component's initializer (which can itself raise
        # NameError) crashes loudly instead of silently dropping the widget. safe_constantize
        # returns nil rather than raising on an unknown constant.
        component_class = registry_entry[:component].safe_constantize
        unless component_class
          Rails.logger.warn "Dashboards::LayoutEngine: Component class '#{registry_entry[:component]}' not found for widget '#{widget_data}'"
          return nil
        end

        extra = registry_entry[:extra_params]&.call(widget_data) || {}
        component_class.new(**base_params, **extra)
      end
    end
  end
end
