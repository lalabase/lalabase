# frozen_string_literal: true

module Neo
  module Buttons
    class ButtonComponentPreview < ViewComponent::Preview
      # Basic button variants
      # @param variant select [primary, secondary, danger, edit, ghost]
      # @param size select [small, medium, large]
      def default(variant: :secondary, size: :medium)
        render Neo::Buttons::ButtonComponent.new(variant: variant, size: size) do
          'Button Text'
        end
      end

      # All button variants
      def all_variants
        render_with_template(locals: {})
      end

      # Button with icon
      # @param icon text
      # @param icon_position select [left, right]
      def with_icon(icon: 'pencil', icon_position: :left)
        render Neo::Buttons::ButtonComponent.new(icon: icon, icon_position: icon_position, variant: :primary) do
          'Edit Item'
        end
      end

      # Button with loading state
      def loading_state
        render Neo::Buttons::ButtonComponent.new(loading: true, variant: :primary) do
          'Processing...'
        end
      end

      # Button with confirmation
      def with_confirmation
        render Neo::Buttons::ButtonComponent.new(
          variant: :danger,
          icon: 'trash',
          confirm: 'Are you sure you want to delete this item?',
          interactive: true
        ) do
          'Delete'
        end
      end

      # Link styled as button
      def as_link
        render Neo::Buttons::ButtonComponent.new(
          tag: :a,
          href: '#',
          variant: :primary,
          icon: 'plus-lg'
        ) do
          'New Item'
        end
      end

      # Disabled button
      def disabled
        render Neo::Buttons::ButtonComponent.new(
          disabled: true,
          variant: :primary
        ) do
          'Disabled Button'
        end
      end

      # Form button (delete action)
      def form_delete
        render Neo::Buttons::ButtonComponent.new(
          variant: :danger,
          icon: 'trash',
          interactive: true,
          confirm: 'This action cannot be undone. Continue?',
          form: {
            action: '/fake/path',
            method: :delete
          }
        ) do
          'Delete Item'
        end
      end
    end
  end
end
