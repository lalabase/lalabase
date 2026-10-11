# frozen_string_literal: true

# Dropdown container component for notifications in the header
#
# ⚠️ Mounted only in the test environment (layouts/application.html.erb,
# `if Rails.env.test?`) for system specs; production renders no bell. It still
# counts by the inbox rule, so the specs that drive it see real numbers.
#
# PURPOSE:
# Container component for the entire notification dropdown with trigger,
# header, notification list and footer actions.
#
# WHY BUILT THIS WAY:
# - Reusable: can be used in various layouts
# - Modular: uses other Neo components for badge and items
# - Interactive: integrates Turbo Streams for real-time updates
# - Accessible: keyboard navigation, screen reader support
# - Performant: lazy loading of notifications
# - Responsive: mobile-optimized presentation
#
# EXAMPLE:
# <%= render NeoNotificationDropdownComponent.new(
#      user: current_user,
#      organisation: current_organisation,
#      limit: 10
#    ) %>

class NeoNotificationDropdownComponent < ViewComponent::Base
  attr_reader :user, :organisation, :limit, :variant, :position, :mobile

  def initialize(user:, organisation:, limit: 10, variant: :default, position: :right, mobile: false)
    @user = user
    @organisation = organisation
    @limit = limit.to_i
    @variant = variant.to_sym
    @position = position.to_sym
    @mobile = mobile
  end

  def render?
    @user.present? && @organisation.present?
  end

  private

  # The inbox rule (Notification.inbox_unread). Counted on its own relation, not
  # on recent_notifications: that one is limited to the rows the menu shows, so
  # the count stopped at @limit.
  def unread_count
    @unread_count ||= @user.unread_notifications_count(@organisation)
  end

  # The rows the inbox would show (accessible_for: no rows of a project the
  # person can no longer reach, none of an archived one). Unlimited; the menu
  # list and the "view all" decision both start here.
  def inbox_rows
    @inbox_rows ||= @user.notifications
                         .where(organisation: @organisation)
                         .channel_in_app
                         .inbox
                         .accessible_for(@user, @organisation)
  end

  def recent_notifications
    # avatar_attachment/blob: each row renders the actor circle, whose attached?
    # check is an N+1 without the preload (same as for_notification_center).
    @recent_notifications ||= inbox_rows.recent
                                        .includes(:notifiable, actor: { avatar_attachment: :blob })
                                        .limit(@limit)
  end

  def dropdown_classes
    classes = %w[dropdown notification-dropdown]
    classes << "notification-dropdown--#{@variant}" unless @variant == :default
    classes.join(' ')
  end

  def dropdown_menu_classes
    if mobile
      # Mobile: full screen for maximum readability
      classes = %w[fixed inset-0 bg-surface-raised overflow-hidden flex flex-col z-modal]
    else
      classes = %w[dropdown-menu notification-dropdown-menu]
      classes << 'dropdown-menu--end' if @position == :right
      classes << 'dropdown-menu--start' if @position == :left
    end
    classes.join(' ')
  end

  def trigger_classes
    if mobile
      classes = ['w-10', 'h-10', 'rounded-full', 'hover:bg-gray-100', 'active:bg-gray-200', 'flex', 'items-center', 'justify-center', 'transition-colors', 'relative']
    else
      classes = ['btn', 'btn--ghost', 'btn--sm', 'notification-trigger']
      classes << 'notification-trigger--active' if unread_count > 0
    end
    classes.join(' ')
  end

  def mark_all_read_path
    helpers.mark_all_read_organisation_notifications_path(@organisation)
  rescue StandardError
    '#'
  end

  def view_all_path
    helpers.organisation_notifications_path(@organisation)
  rescue StandardError
    '#'
  end

  def preferences_path
    helpers.preferences_organisation_notifications_path(@organisation)
  rescue StandardError
    '#'
  end

  def turbo_stream_channel
    Notifications::Streams.notifications(@user, @organisation)
  end

  def dropdown_id
    "notification-dropdown-#{@user.id}"
  end

  def notifications_list_id
    "notifications-list-#{@user.id}"
  end

  def show_empty_state?
    recent_notifications.empty?
  end

  def show_view_all_button?
    inbox_rows.count > @limit
  end

  def header_title
    case @variant
    when :compact
      'Notifications'
    else
      'Recent Notifications'
    end
  end
end
