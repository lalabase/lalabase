# frozen_string_literal: true

module Neo
  module Buttons
    class WatchButtonComponent < ViewComponent::Base
      def initialize(item:, user:, size: :medium, icon_only: false, **options)
        @item = item
        @user = user
        @size = size
        @icon_only = icon_only
        @options = options

        @subscription = NotificationSubscription.for_user(@user)
                                                .for_item(@item)
                                                .first
      end

      def render?
        can_view_item?
      end

      private

      def can_view_item?
        case @item
        when Ticket
          @user.can_view_ticket?(@item)
        when Project
          @user.can_view_project?(@item)
        else
          false
        end
      rescue StandardError
        false
      end

      def watching?
        @subscription&.mode_follow? || false
      end

      # What auto-subscribe rules would say for this user/item
      def auto_state
        return false unless @item.is_a?(Ticket)

        @item.assignee_ids.include?(@user.id) ||
          (@item.creator_id == @user.id && @user.ticket_auto_follow_created?)
      end

      # True when user's manual state differs from what auto-rules would set
      def override?
        @item.is_a?(Ticket) && watching? != auto_state
      end

      def override_text
        return nil unless override?

        if watching?
          t('components.neo.buttons.watch_button.override_active')
        else
          t('components.neo.buttons.watch_button.override_inactive')
        end
      end

      def button_icon
        watching? ? 'bell' : 'bell-slash'
      end

      def button_variant
        watching? ? :primary : :ghost
      end

      def button_text
        return nil if @icon_only

        watching? ? t('components.neo.buttons.watch_button.text_active') : t('components.neo.buttons.watch_button.text_inactive')
      end

      def button_title
        if watching?
          t('components.neo.buttons.watch_button.title_deactivate')
        else
          t('components.neo.buttons.watch_button.title_activate')
        end
      end

      def toggle_path
        case @item
        when Ticket
          toggle_organisation_project_ticket_subscription_path(
            @item.organisation,
            @item.project,
            @item
          )
        when Project
          toggle_organisation_project_subscription_path(
            @item.organisation,
            @item
          )
        end
      end

      def dom_id
        "watch_button_#{@item.class.name.underscore}_#{@item.id}"
      end

      def button_component_class
        @icon_only ? Neo::Buttons::IconButtonComponent : Neo::Buttons::ButtonComponent
      end

      def button_attributes
        {
          variant: button_variant,
          size: @size,
          icon: button_icon,
          title: button_title,
          form: {
            action: toggle_path,
            method: :post
          }
        }.merge(@options)
      end
    end
  end
end
