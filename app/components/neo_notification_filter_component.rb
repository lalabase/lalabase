# frozen_string_literal: true

class NeoNotificationFilterComponent < ViewComponent::Base
  include Notifications::Constants
  include SegmentStylesHelper

  def initialize(current_filters:, filter_url:, projects:)
    @current_filters = current_filters
    @filter_url = filter_url
    @projects = projects
  end

  private

  attr_reader :current_filters, :filter_url, :projects

  # --- Pill-Helpers ---------------------------------------------------------

  PILL_BASE = 'inline-flex items-center px-3 py-1 rounded-full text-xs font-medium border transition-colors'
  # Active = warm fill (cream-200) + thin ink border + bold (Part G/G4: NOT lime,
  # but also NO dark block — that was too heavy as a permanent pill). Clearly "on" via
  # border + weight, not via surface.
  PILL_ACTIVE = 'border-ink bg-cream-200 text-cream-900 font-semibold'
  PILL_INACTIVE = 'border-cream-300 bg-cream-50 text-cream-700 hover:bg-cream-100 hover:border-cream-400'

  def pill_classes(active)
    "#{PILL_BASE} #{active ? PILL_ACTIVE : PILL_INACTIVE}"
  end

  # Multi-select toggle: takes an array param (e.g. state_filters[])
  # and toggles the given value in/out.
  # On an empty selection we keep an empty marker (?state_filters[]=)
  # so that the default redirect to state_filters[]=unread does NOT fire —
  # the user explicitly deselected, which should be respected.
  def toggle_array_param_url(key, value)
    current = helpers.request.query_parameters.dup
    current_values = Array(current[key.to_s]).reject(&:blank?)
    new_values = current_values.include?(value) ? current_values - [value] : current_values + [value]
    if new_values.any?
      current[key.to_s] = new_values
      build_url(current)
    else
      current.delete(key.to_s)
      # Set an explicit "no filter" marker as an empty array entry,
      # so that request.query_string is not blank.
      base = current.any? ? "#{filter_url}?#{current.to_query}&" : "#{filter_url}?"
      "#{base}#{key}[]="
    end
  end

  # Set: always sets the param to the desired value (for the view-mode
  # toggle, which should always have a value).
  def set_param_url(key, value)
    current = helpers.request.query_parameters.dup
    current[key.to_s] = value
    build_url(current)
  end

  def build_url(query_params)
    if query_params.empty?
      filter_url
    else
      "#{filter_url}?#{query_params.to_query}"
    end
  end

  def checkbox_icon(active)
    icon = active ? 'check-square-fill' : 'square'
    color = active ? '' : 'text-cream-500'
    "<i class=\"bi bi-#{icon} text-[13px] #{color}\"></i>".html_safe
  end

  # --- Pill definitions -----------------------------------------------------

  def state_pills
    [
      ['unread',   t('views.organisations.notifications.filter.unread',   default: 'Ungelesen')],
      ['read',     t('views.organisations.notifications.filter.read',     default: 'Gelesen')],
      ['archived', t('views.organisations.notifications.filter.archived', default: 'Archiviert')]
    ]
  end

  # Read active state filters from an array or (backward-compat) single string.
  def active_state_filters
    arr = Array(current_filters[:state_filters]).reject(&:blank?)
    arr = [current_filters[:state]] if arr.empty? && current_filters[:state].present?
    arr
  end

  def state_pill_active?(value)
    active_state_filters.include?(value)
  end

  def view_mode_pills
    [
      ['chronological',
       t('views.organisations.notifications.filter.view_chronological', default: 'Chronologisch'),
       'list-ul'],
      ['grouped',
       t('views.organisations.notifications.filter.view_grouped', default: 'Gruppiert'),
       'collection']
    ]
  end

  def current_view_mode
    current_filters[:view_mode].presence || 'grouped'
  end

  # --- Extended filters -----------------------------------------------------

  def event_type_options
    [
      [t('views.organisations.notifications.filter.all_types', default: 'Alle Typen'), ''],
      [t('views.organisations.notifications.event_short.ticket_commented',      default: 'Kommentare'),       EVENT_TYPE_TICKET_COMMENTED],
      [t('views.organisations.notifications.event_short.ticket_assigned',       default: 'Zuweisungen'),      EVENT_TYPE_TICKET_ASSIGNED],
      [t('views.organisations.notifications.event_short.ticket_status_changed', default: 'Statusänderungen'), EVENT_TYPE_TICKET_STATUS_CHANGED],
      [t('views.organisations.notifications.event_short.project_announcement',  default: 'Ankündigungen'),    EVENT_TYPE_PROJECT_ANNOUNCEMENT],
      [t('views.organisations.notifications.event_short.document_added',        default: 'Dokumente'),        EVENT_TYPE_DOCUMENT_ADDED],
      [t('views.organisations.notifications.event_short.mention',               default: 'Erwähnungen'),      EVENT_TYPE_MENTION],
      [t('views.organisations.notifications.event_short.system_message',        default: 'System'),           EVENT_TYPE_SYSTEM_MESSAGE]
    ]
  end

  def project_options
    [[t('views.organisations.notifications.filter.all_projects', default: 'Alle Projekte'), '']] +
      projects.map { |project| [project.name, project.id] }
  end

  def has_extended_filters?
    current_filters[:project_id].present? ||
      current_filters[:event_type].present? ||
      current_filters[:search].present?
  end
end
