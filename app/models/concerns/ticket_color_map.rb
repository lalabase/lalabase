# frozen_string_literal: true

# Central mapping of status and priority values to CSS classes (dot colors).
# Used both by ApplicationHelper and by dashboard components.
#
# The status colours are the status ladder of the surface table
# (doc/belegungstabelle_oberflaeche.md, F16: green, amber, red, cobalt, cream;
# finding B27: lime is the main action's colour and never a status). Since
# 08.09.2026 a state's colour comes from its system function (is_new,
# is_in_progress, ...) before a colour stored on the option, so no hex value
# ever reaches the markup for a state the system knows.
module TicketColorMap
  STATUS_COLORS = {
    'offen' => 'bg-cobalt-500',
    'open' => 'bg-cobalt-500',
    'neu' => 'bg-cobalt-500',
    'new' => 'bg-cobalt-500',
    'in bearbeitung' => 'bg-amber-500',
    'in arbeit' => 'bg-amber-500',
    'in progress' => 'bg-amber-500',
    'bearbeitung' => 'bg-amber-500',
    'erledigt' => 'bg-green-500',
    'fertig' => 'bg-green-500',
    'done' => 'bg-green-500',
    'abgeschlossen' => 'bg-green-500',
    'geschlossen' => 'bg-cream-500',
    'closed' => 'bg-cream-500'
  }.freeze

  PRIORITY_COLORS = {
    'hoch' => 'bg-red-500',
    'high' => 'bg-red-500',
    'dringend' => 'bg-red-500',
    'urgent' => 'bg-red-500',
    'critical' => 'bg-red-500',
    'kritisch' => 'bg-red-500',
    'mittel' => 'bg-amber-500',
    'medium' => 'bg-amber-500',
    'normal' => 'bg-amber-500',
    'niedrig' => 'bg-cobalt-500',
    'low' => 'bg-cobalt-500',
    'gering' => 'bg-cobalt-500'
  }.freeze

  # Status values that count as "closed" (green + cream in STATUS_COLORS)
  CLOSED_STATUS_COLORS = %w[bg-green-500 bg-cream-500].freeze
  CLOSED_STATUSES = STATUS_COLORS.select { |_, color| CLOSED_STATUS_COLORS.include?(color) }.keys.freeze

  # System-function-based colors (dot colors): the ladder's hues at dot strength.
  SYSTEM_FUNCTION_DOT_COLORS = {
    SystemFunctions::Registry::IS_BACKLOG => 'bg-cream-400',
    SystemFunctions::Registry::IS_NEW => 'bg-cobalt-500',
    SystemFunctions::Registry::IS_OPEN => 'bg-cobalt-500',
    SystemFunctions::Registry::IS_IN_PROGRESS => 'bg-amber-500',
    SystemFunctions::Registry::IS_COMPLETED => 'bg-green-500',
    SystemFunctions::Registry::IS_CLOSED => 'bg-cream-500',
    SystemFunctions::Registry::HIGH_PRIORITY => 'bg-red-500'
  }.freeze

  # System-function-based badge colors: the ladder's tints (F16) with ink text.
  SYSTEM_FUNCTION_BADGE_COLORS = {
    SystemFunctions::Registry::IS_BACKLOG => 'bg-cream-200 text-cream-700',
    SystemFunctions::Registry::IS_NEW => 'bg-cobalt-100 text-cobalt-900',
    SystemFunctions::Registry::IS_OPEN => 'bg-cobalt-100 text-cobalt-900',
    SystemFunctions::Registry::IS_IN_PROGRESS => 'bg-amber-100 text-amber-900',
    SystemFunctions::Registry::IS_COMPLETED => 'bg-green-100 text-green-900',
    SystemFunctions::Registry::IS_CLOSED => 'bg-cream-200 text-cream-600',
    SystemFunctions::Registry::HIGH_PRIORITY => 'bg-red-100 text-red-900'
  }.freeze

  # Priority badge colors: the theme's scales (red, amber, cobalt), never Tailwind's blue or gray.
  PRIORITY_BADGE_COLORS = {
    'hoch' => 'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200',
    'high' => 'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200',
    'dringend' => 'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200',
    'urgent' => 'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200',
    'critical' => 'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200',
    'kritisch' => 'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200',
    'mittel' => 'bg-amber-100 text-amber-900',
    'medium' => 'bg-amber-100 text-amber-900',
    'normal' => 'bg-amber-100 text-amber-900',
    'niedrig' => 'bg-cobalt-100 text-cobalt-900',
    'low' => 'bg-cobalt-100 text-cobalt-900',
    'gering' => 'bg-cobalt-100 text-cobalt-900'
  }.freeze

  DEFAULT_BADGE_COLOR = 'bg-cream-200 text-cream-700'
  DEFAULT_DOT_COLOR = 'bg-cream-400'

  def self.status_dot_color(value)
    STATUS_COLORS[value.to_s.downcase] || DEFAULT_DOT_COLOR
  end

  def self.priority_dot_color(value)
    PRIORITY_COLORS[value.to_s.downcase] || DEFAULT_DOT_COLOR
  end

  # Dot color based on system-function key
  def self.dot_color_for_function(function_key)
    SYSTEM_FUNCTION_DOT_COLORS[function_key.to_s] || DEFAULT_DOT_COLOR
  end

  # Badge color based on system-function key
  def self.badge_color_for_function(function_key)
    SYSTEM_FUNCTION_BADGE_COLORS[function_key.to_s] || DEFAULT_BADGE_COLOR
  end

  # Priority badge color (light background + text color, with dark mode)
  def self.priority_badge_color(value)
    PRIORITY_BADGE_COLORS[value.to_s.downcase] || DEFAULT_BADGE_COLOR
  end
end
