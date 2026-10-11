# frozen_string_literal: true

# Badge component for the notification counter in the header
#
# PURPOSE:
# Displays the number of unread notifications as a badge.
# Supports various variants and sizes.
#
# WHY BUILT THIS WAY:
# - Reusable: can be used in various contexts
# - Responsive: adapts to various screen sizes
# - Accessible: screen reader support and ARIA labels
# - Performant: ViewComponent is faster than partials
# - Consistent: follows the Neo Brutalist design system
#
# EXAMPLE:
# <%= render NeoNotificationBadgeComponent.new(count: 5) %>
# <%= render NeoNotificationBadgeComponent.new(count: 150, variant: :large) %>

class NeoNotificationBadgeComponent < ViewComponent::Base
  attr_reader :count, :variant, :max_count, :css_class

  def initialize(count:, variant: :default, max_count: 99, css_class: nil)
    @count = count.to_i
    @variant = variant.to_sym
    @max_count = max_count.to_i
    @css_class = css_class
  end

  def render?
    @count > 0
  end

  private

  def display_count
    @count > @max_count ? "#{@max_count}+" : @count.to_s
  end

  def badge_classes
    classes = ['notification-badge']
    classes << variant_classes
    classes << @css_class if @css_class
    classes.compact.join(' ')
  end

  def variant_classes
    case @variant
    when :small
      'notification-badge--small'
    when :large
      'notification-badge--large'
    when :dot
      'notification-badge--dot'
    else
      'notification-badge--default'
    end
  end

  def aria_label
    if @count == 1
      '1 unread notification'
    else
      "#{@count} unread notifications"
    end
  end

  def wrapper_classes
    base = 'notification-badge-wrapper'
    base += " notification-badge-wrapper--#{@variant}" unless @variant == :default
    base
  end
end
