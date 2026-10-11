# frozen_string_literal: true

module Neo
  # The "Benachrichtigt" line of a ticket (Slack-flat since the user mockup
  # 05.09.2026): one text line naming the subscribers in the viewer's
  # spelling, and "aendern" turns it into a checkbox list IN PLACE - no
  # modal, no navigation. Every checkbox submits immediately; the Turbo
  # replace keeps the editor open via the subscriber_open param (open:).
  # The compact mode (bell + hover popover) is untouched by that round.
  class SubscriberListComponent < ViewComponent::Base
    MAX_INLINE_INACTIVE = 2
    # The editor offers a handful of not-yet-subscribed people as unchecked
    # rows; everyone else is reachable through "Person suchen".
    MAX_EDITOR_INACTIVE = 5

    attr_reader :mode

    def initialize(item:, current_user:, mode: 'full_inline', open: false)
      @item = item
      @current_user = current_user
      @mode = mode
      @open = open
      # Chips render per row (register rule 6): preload the avatars.
      @subscriptions = item.notification_subscriptions
                           .visible
                           .with_subscribers
                           .includes(user: { avatar_attachment: :blob })
                           .order(:created_at)
      @current_user_subscription = item.notification_subscriptions
                                       .for_user(current_user)
                                       .first
    end

    def open?
      @open
    end

    def render?
      true
    end

    def compact?
      @mode == 'compact'
    end

    def active_subscriber_count
      @subscriptions.count
    end

    def dom_id
      "subscriber_list_#{@item.class.name.underscore}_#{@item.id}"
    end

    def current_user_entry
      {
        user: @current_user,
        subscription: @current_user_subscription,
        is_current_user: true,
        watching: watching?,
        muted: muted?,
        label: current_user_label
      }
    end

    def other_subscriber_entries
      @subscriptions.reject { |sub| sub.user_id == @current_user.id }.map do |sub|
        {
          subscription: sub,
          user: sub.user,
          is_current_user: false,
          label: source_label(sub),
          removable: removable?(sub)
        }
      end
    end

    def watching?
      @current_user_subscription&.mode_follow? || false
    end

    def muted?
      @current_user_subscription&.mode_mute? || false
    end

    def toggle_url
      case @item
      when Ticket
        helpers.toggle_organisation_project_ticket_subscription_path(
          organisation_id: @item.organisation.id,
          project_id: @item.project.id,
          ticket_id: @item.id
        )
      end
    end

    def source_label(subscription)
      case subscription.source
      when NotificationSubscription::SOURCE_CREATOR
        t('views.shared.subscriber_list.source_creator')
      when NotificationSubscription::SOURCE_ASSIGNEE
        t('views.shared.subscriber_list.source_assignee')
      when NotificationSubscription::SOURCE_SELF
        t('views.shared.subscriber_list.source_self')
      when NotificationSubscription::SOURCE_MANUAL
        if subscription.subscribed_by
          t('views.shared.subscriber_list.source_manual',
            name: helpers.viewer_display_name(subscription.subscribed_by))
        else
          t('views.shared.subscriber_list.source_manual_unknown')
        end
      else
        t('views.shared.subscriber_list.source_self')
      end
    end

    def removable?(subscription)
      subscription.source == NotificationSubscription::SOURCE_MANUAL
    end

    def subscribe_other_url
      case @item
      when Ticket
        helpers.subscribe_other_organisation_project_ticket_subscription_path(
          organisation_id: @item.organisation.id,
          project_id: @item.project.id,
          ticket_id: @item.id
        )
      end
    end

    def unsubscribe_url(subscription)
      case @item
      when Ticket
        helpers.unsubscribe_other_organisation_project_ticket_subscription_path(
          organisation_id: @item.organisation.id,
          project_id: @item.project.id,
          ticket_id: @item.id,
          subscription_id: subscription.id
        )
      end
    end

    def available_users_url
      case @item
      when Ticket
        helpers.available_users_organisation_project_ticket_subscription_path(
          organisation_id: @item.organisation.id,
          project_id: @item.project.id,
          ticket_id: @item.id
        )
      end
    end

    def inactive_member_entries
      non_subscribed_project_members.first(MAX_INLINE_INACTIVE).map do |user|
        { user: user }
      end
    end

    def editor_inactive_entries
      non_subscribed_project_members.first(MAX_EDITOR_INACTIVE).map do |user|
        { user: user }
      end
    end

    # Adding or removing OTHER people requires write access to the item;
    # without it the editor still lets the viewer toggle their own row.
    def can_manage_others?
      helpers.policy(@item).update?
    rescue StandardError
      false
    end

    # The collapsed line: "G. Boyke (Du), A. Berg" in the viewer's spelling,
    # the viewer first when subscribed - own name plus the marker, not a bare
    # "du" (user decision 05.09.2026).
    def collapsed_names_text
      names = []
      names << viewer_own_label if watching?
      names += other_subscriber_entries.map { |entry| helpers.viewer_display_name(entry[:user]) }
      return t('views.shared.subscriber_list.nobody') if names.empty?

      names.join(', ')
    end

    def viewer_own_label
      "#{helpers.viewer_display_name(@current_user)} (#{t('views.shared.subscriber_list.you')})"
    end

    # A subscriber pill is an identity label: avatar chip + name in the
    # viewer's spelling (Slack model, user decision 05.09.2026 — the picture
    # always shows, the setting only spells the name). Confirm dialogs and
    # hover titles keep the full name.
    def display_name(entry)
      return t('views.shared.subscriber_list.you') if entry[:is_current_user]

      user_label(entry[:user])
    end

    def user_label(user)
      helpers.viewer_user_chip(user)
    end

    private

    def non_subscribed_project_members
      @non_subscribed_project_members ||= compute_non_subscribed_members
    end

    def compute_non_subscribed_members
      project = project_for_item
      return [] unless project

      # All user IDs that already have any subscription (follow or mute) + current user
      subscribed_user_ids = @item.notification_subscriptions.pluck(:user_id)
      excluded_ids = (subscribed_user_ids + [@current_user.id]).uniq

      # Project#assignable_users: active members only, the people the
      # subscription write accepts.
      project.assignable_users
             .where.not(id: excluded_ids)
             .includes(avatar_attachment: :blob)
             .order(:first_name, :last_name)
             .limit(MAX_EDITOR_INACTIVE + 1)
             .to_a
    end

    def project_for_item
      case @item
      when Ticket then @item.project
      end
    end

    def current_user_label
      if watching? && @current_user_subscription
        source_label(@current_user_subscription)
      elsif muted?
        t('views.shared.subscriber_list.muted_label')
      else
        t('views.shared.subscriber_list.not_subscribed')
      end
    end
  end
end
