# frozen_string_literal: true

# Overview widget: the per-project portfolio table (unread + billing hours + last activity).
# Thin presentation wrapper around the shared Dashboard::DailyBriefing#projects_overview (already
# Policy::Scope-gated). Permission-only should_render? (always true): the table is org-wide and
# self-scopes, so an empty result is shown via the in-component empty state, not a hidden widget.
#
# The two billing-hours COLUMNS are gated on time access (show_billing?): the figures are already
# scoped to 0 for a viewer without time_sessions:read, but the columns themselves are hidden from them
# rather than shown as a row of zeros — consistent with billing_overview / the org_stats_cards card.
#
# Project selection (config from the editor): `mode` picks WHICH projects show — all (default),
# `selected` (an explicit `selected_ids` list), `pinned` (sidebar-nav pins), or `with_entries`
# (unread notifications OR not-yet-billed hours). The filter runs in-memory over the shared
# briefing's already policy-scoped projects_overview, so it adds no query and can never surface a
# project the viewer may not see (stale/inaccessible ids simply drop out).
class Overview::ProjectsTableComponent < ViewComponent::Base
  # Single source of truth for the selection modes, shared by all three call sites: the registry
  # `parse` (save whitelist), this component (render whitelist + filter), and the editor radio group.
  # DEFAULT_MODE is the unfiltered table and is never persisted (parse strips it). The editor offers
  # DEFAULT_MODE first, then the SELECTION_MODES; each mode's i18n label is "...mode_<mode>".
  DEFAULT_MODE = 'all'
  SELECTION_MODES = %w[selected pinned with_entries].freeze
  EDITOR_MODES = ([DEFAULT_MODE] + SELECTION_MODES).freeze

  def initialize(organisation:, user:, briefing:, mode: nil, selected_ids: nil)
    @organisation = organisation
    @user = user
    @briefing = briefing
    @mode = mode.to_s.presence_in(SELECTION_MODES) # nil/forged => all
    @selected_ids = Array(selected_ids).map(&:to_s)
  end

  def should_render?
    true
  end

  private

  attr_reader :organisation, :user, :briefing

  # Whether to show the billing-hours columns: only for a viewer with time access in some project
  # (the org primitive). Current memoises the underlying check, so calling this per row is cheap.
  def show_billing?
    Current.area_access_anywhere?(user, organisation, :time_sessions, :read)
  end

  # Hide the unread column entirely when NO project has unread notifications — an all-"—" column is
  # pure visual noise. (Individual "—" still appear for zero rows when some other project has unread.)
  def show_unread?
    total_unread.positive?
  end

  def project_rows
    @project_rows ||= filter_rows(briefing.projects_overview)
  end

  # Applies the configured selection mode. One place so body, footer totals and the empty state
  # all agree on the same filtered set.
  def filter_rows(rows)
    case @mode
    when 'selected'     then rows.select { |r| @selected_ids.include?(r[:project].id.to_s) }
    when 'pinned'       then rows.select { |r| user.sidebar_pins.project_pinned?(organisation, r[:project].id) }
    when 'with_entries' then rows.select { |r| row_has_entries?(r) }
    else rows
    end
  end

  # "Has entries" = an unread in-app notification OR any not-yet-billed hours (both billed:false
  # buckets count — in billing and not billed, per the unbilled definition).
  def row_has_entries?(row)
    row[:unread_count].positive? ||
      row[:in_billing_hours].positive? ||
      row[:without_billing_hours].positive?
  end

  # Mode-specific empty-state copy so an empty table explains WHY it is empty (no selection / no
  # pins / nothing open) instead of the generic "no access" line, which only fits the `all` mode.
  def empty_state_message
    case @mode
    when 'selected'     then t('dashboard.briefing.sections.projects.empty_selected')
    when 'pinned'       then t('dashboard.briefing.sections.projects.empty_pinned')
    when 'with_entries' then t('dashboard.briefing.sections.projects.empty_with_entries')
    else t('dashboard.briefing.sections.projects.empty')
    end
  end

  # Footer totals. Rounded to match the per-row hour formatting.
  def total_unread
    project_rows.sum { |r| r[:unread_count] }
  end

  def total_in_billing
    project_rows.sum { |r| r[:in_billing_hours] }.round(1)
  end

  def total_without_billing
    project_rows.sum { |r| r[:without_billing_hours] }.round(1)
  end

  def current_organisation
    organisation
  end
end
