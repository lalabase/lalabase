# frozen_string_literal: true

module Overview
  # Widget catalogue for the organisation overview (briefings#show) — the org-scoped
  # sibling of Dashboards::LayoutEngine::WIDGET_REGISTRY. Same entry shape (label_key,
  # component, units, permission, optional extra_params/parse/settings_partial); bound
  # to the one shared engine via the registry parameter (no duplicated logic).
  #
  # 5 converted briefing sections (org_activity_feed / projects_table / my_week_* / unread_summary)
  # plus the 4 portfolio widgets (org_stats_cards / my_open_tickets / my_mentions / billing_overview)
  # backed by Overview::PortfolioStats.
  #
  # NOTE on permissions: overview widgets aggregate across ALL the viewer's projects, so
  # their visibility is an "access in ANY project" question, resolved by the org-aware
  # permission primitive (built where it is consumed, in the render/editor path) — not the
  # single-project ProjectPolicy used by the project dashboard. The :permission entries here
  # are declarative intent; the render path maps them through the org primitive.
  module WidgetRegistry
    WIDGETS = {
      'org_activity_feed' => {
        label_key: 'overview.widgets.org_activity_feed',
        component: 'Overview::ActivityFeedComponent',
        units: 3,
        permission: nil,
        extra_params: ->(data) { { limit: data['limit'] } },
        # Editor save (D3): only a whitelisted limit is stored; anything else keeps the default.
        parse: ->(w) { (limit = Dashboards::LayoutEngine.sanitized_item_limit(w[:limit])) ? { 'limit' => limit } : {} }
      },
      'projects_table' => {
        label_key: 'overview.widgets.projects_table',
        component: 'Overview::ProjectsTableComponent',
        units: 4,
        permission: nil,
        # Project selection mode. extra_params feeds the live preview + the component constructor;
        # parse owns the stored shape. The presence of :extra_params is what flips the editor's
        # has_settings gate on, so the settings form (mode radios + project picker) appears.
        extra_params: ->(data) { { mode: data['mode'], selected_ids: data['project_ids'] } },
        # 'all' is the default and is NOT persisted (storing it would be noise). Only the non-default
        # modes are whitelisted — the SAME list the component enforces on render (single source of
        # truth, no drift). A forged mode falls back to 'all'. project_ids is kept only for the
        # 'selected' mode and only when it is a real array of ids (a forged scalar/hash param is
        # dropped — the render path re-filters against the policy-scoped set regardless).
        parse: lambda { |w|
          mode = w[:mode].to_s.presence_in(Overview::ProjectsTableComponent::SELECTION_MODES)
          result = mode ? { 'mode' => mode } : {}
          if mode == 'selected'
            raw = w[:project_ids]
            ids = raw.is_a?(Array) ? raw.map(&:to_s).reject(&:blank?).uniq : []
            result['project_ids'] = ids if ids.present?
          end
          result
        }
      },
      'my_week_stats' => {
        label_key: 'overview.widgets.my_week_stats',
        component: 'Overview::WeekStatsComponent',
        units: 2,
        permission: { area: :time_sessions, action: :read }
      },
      'my_week_chart' => {
        label_key: 'overview.widgets.my_week_chart',
        component: 'Overview::WeekChartComponent',
        units: 2,
        permission: { area: :time_sessions, action: :read }
        # No :extra_params in v1 → no settings form (has_settings is gated on it). The chart's `period`
        # is reserved for a future range selector (WeekChartComponent ignores it today); it gets its
        # settings field back together with the working range selector, not as an inert control.
      },
      'unread_summary' => {
        label_key: 'overview.widgets.unread_summary',
        component: 'Overview::UnreadSummaryComponent',
        units: 1,
        permission: nil
      },
      'org_stats_cards' => {
        label_key: 'overview.widgets.org_stats_cards',
        component: 'Overview::OrgStatsCardsComponent',
        units: 3,
        permission: nil,
        # Card picker: which key figures to show. extra_params feeds the live preview; parse stores
        # only whitelisted keys (in canonical order). An all-empty selection is blocked by the editor's
        # empty-card guard (stats_widget_keys), so parse never needs to invent a fallback here.
        extra_params: ->(data) { { card_keys: data['card_keys'] } },
        parse: lambda { |w|
          keys = Overview::OrgStatsCardsComponent::CARD_KEYS & Array(w[:card_keys]).map(&:to_s)
          keys.present? ? { 'card_keys' => keys } : {}
        }
      },
      'my_open_tickets' => {
        label_key: 'overview.widgets.my_open_tickets',
        component: 'Overview::MyOpenTicketsComponent',
        units: 3,
        permission: { area: :tickets, action: :read },
        # group_keys = which due-date buckets show as labeled sections (see the component's GROUP_KEYS);
        # deduplicate = show each ticket only once (in its narrowest matching bucket); display_mode =
        # sections (stacked, default) or tabs (switchable pills). parse stores only whitelisted values;
        # an empty/forged selection is dropped so the component falls back to its defaults (all_open /
        # off / sections), so only explicit non-defaults are persisted.
        extra_params: ->(data) { { limit: data['limit'], group_keys: data['group_keys'], deduplicate: data['deduplicate'], display_mode: data['display_mode'] } },
        parse: lambda { |w|
          parsed = {}
          if (limit = Dashboards::LayoutEngine.sanitized_item_limit(w[:limit]))
            parsed['limit'] = limit
          end
          keys = Overview::MyOpenTicketsComponent::GROUP_KEYS & Array(w[:group_keys]).map(&:to_s)
          parsed['group_keys'] = keys if keys.present?
          parsed['deduplicate'] = true if ActiveModel::Type::Boolean.new.cast(w[:deduplicate])
          # Only the non-default mode ('tabs') is persisted; 'sections' and anything forged are dropped.
          parsed['display_mode'] = 'tabs' if w[:display_mode].to_s == 'tabs'
          parsed
        }
      },
      'my_mentions' => {
        label_key: 'overview.widgets.my_mentions',
        component: 'Overview::MyMentionsComponent',
        units: 2,
        permission: nil,
        extra_params: ->(data) { { limit: data['limit'] } },
        parse: ->(w) { (limit = Dashboards::LayoutEngine.sanitized_item_limit(w[:limit])) ? { 'limit' => limit } : {} }
      },
      'billing_overview' => {
        label_key: 'overview.widgets.billing_overview',
        component: 'Overview::BillingOverviewComponent',
        units: 3,
        permission: { area: :time_sessions, action: :read },
        # Stage picker: which billing-pipeline stages to show (mirrors org_stats_cards' card picker).
        # extra_params feeds the live preview; parse stores only whitelisted keys in canonical order.
        # All-empty is blocked by the editor's empty-card guard (stats_widget_keys includes
        # billing_overview), so parse never needs a fallback here.
        extra_params: ->(data) { { stage_keys: data['stage_keys'] } },
        parse: lambda { |w|
          keys = Overview::BillingOverviewComponent::STAGE_KEYS & Array(w[:stage_keys]).map(&:to_s)
          keys.present? ? { 'stage_keys' => keys } : {}
        }
      },
      'recent_notifications' => {
        label_key: 'overview.widgets.recent_notifications',
        component: 'Overview::RecentNotificationsComponent',
        units: 2,
        permission: nil,
        extra_params: ->(data) { { limit: data['limit'] } },
        parse: ->(w) { (limit = Dashboards::LayoutEngine.sanitized_item_limit(w[:limit])) ? { 'limit' => limit } : {} }
      }
    }.freeze

    # Default overview layout: at-a-glance org numbers up top, then the viewer's own work, then the
    # portfolio table + mentions, then the personal week. Each row's widget minimums sum to <= ROW_UNITS
    # (6) so the row can actually hold them. The user can reconfigure everything in the editor; this is
    # only the starting point. Permission-gated widgets (my_open_tickets / billing_overview / week*)
    # simply don't render for a viewer without the right access — the row reflows around them.
    SYSTEM_DEFAULT_LAYOUT = [
      { 'widgets' => %w[org_stats_cards billing_overview] }, # 3 + 3
      { 'widgets' => %w[my_open_tickets org_activity_feed] }, # 3 + 3
      { 'widgets' => %w[projects_table my_mentions] },        # 4 + 2
      { 'widgets' => %w[my_week_stats my_week_chart recent_notifications] } # 2 + 2 + 2
    ].freeze
  end
end
