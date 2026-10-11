# frozen_string_literal: true

# Icon-Only Button — compact button without a text label.
# Used for toolbar actions, close-X, table actions etc.
#
# Example:
#   <%= render Neo::Buttons::IconButtonComponent.new(icon: "pencil", variant: :edit, title: "Edit") %>
#
module Neo
  module Buttons
    class IconButtonComponent < ViewComponent::Base
      include Neo::Buttons::Base

      # Square sizes: an icon-only button is as wide as it is tall (user,
      # 04.09.2026); text-* scales the Bootstrap icon glyph like in SIZES.
      ICON_SIZES = {
        small: 'h-6 w-6 text-xs',
        medium: 'h-8 w-8 text-sm',
        large: 'h-10 w-10 text-base'
      }.freeze

      def initialize(
        icon:,
        variant: :secondary,
        size: :medium,
        tag: :button,
        loading: false,
        disabled: false,
        confirm: nil,
        interactive: false,
        form: nil,
        url: nil,
        **options
      )
        @icon = icon
        @variant = variant.to_sym
        @size = size.to_sym
        @url = url
        @tag = url.present? ? :a : tag
        @loading = loading
        @disabled = disabled
        @confirm = confirm
        @interactive = interactive || loading || confirm.present?
        @form = form
        @options = options
      end

      private

      # Icon-only buttons are square (width = height), no horizontal padding.
      def size_classes
        ICON_SIZES[@size]
      end

      def render_icon
        return plus_cross_svg(18) if primary? && @icon.to_s == 'plus-lg'

        content_tag(:i, '', class: "bi bi-#{@icon}")
      end
    end
  end
end
