# frozen_string_literal: true

# Action Button — button with a text label (optionally with an icon).
# Used for primary actions like "New task", "Send", "Delete" etc.
#
# For icon-only buttons → use Neo::Buttons::IconButtonComponent.
#
# Example:
#   <%= render Neo::Buttons::ButtonComponent.new(variant: :primary, icon: "plus-lg") { "New task" } %>
#
module Neo
  module Buttons
    class ButtonComponent < ViewComponent::Base
      include Neo::Buttons::Base

      def initialize(
        variant: :secondary,
        size: :medium,
        tag: :button,
        loading: false,
        disabled: false,
        confirm: nil,
        interactive: false,
        icon: nil,
        icon_position: :left,
        form: nil,
        url: nil,
        **options
      )
        @variant = variant.to_sym
        @size = size.to_sym
        @url = url
        @tag = url.present? ? :a : tag
        @loading = loading
        @disabled = disabled
        @confirm = confirm
        @interactive = interactive || loading || confirm.present?
        @icon = icon
        @icon_position = icon_position.to_sym
        @form = form
        @options = options
      end

      # The main action's word button: padding 7 px 14 px at 13 px, weight 600
      # (user, 08.09.2026); h-8 is the 32 px every main action shares.
      PRIMARY_SIZES = {
        small: 'h-6 px-2.5 text-xs',
        medium: 'h-8 px-[14px] text-[13px]',
        large: 'h-10 px-4 text-[15px]'
      }.freeze

      private

      def size_classes
        primary? ? PRIMARY_SIZES[@size] : super
      end

      def render_icon(position)
        return unless @icon && @icon_position == position

        margin = position == :left ? 'mr-2 max-sm:mr-0' : 'ml-2 max-sm:ml-0'
        return plus_cross_svg(16, margin) if primary? && @icon.to_s == 'plus-lg'

        content_tag(:i, '', class: "bi bi-#{@icon} #{margin}")
      end
    end
  end
end
