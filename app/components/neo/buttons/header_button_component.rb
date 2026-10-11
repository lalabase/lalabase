# frozen_string_literal: true

# Header Button — button for the title-box header bar.
# Uses label: instead of a content block so that the text renders reliably.
# Text is responsive: icon only on mobile, with label from sm: upwards.
#
# Examples:
#   <%= render Neo::Buttons::HeaderButtonComponent.new(variant: :primary, icon: "plus-lg", label: "Task", url: new_task_path) %>
#   <%= render Neo::Buttons::HeaderButtonComponent.new(variant: :primary, icon: "plus-lg", label: "Task", responsive: false) %>
#
module Neo
  module Buttons
    class HeaderButtonComponent < ViewComponent::Base
      include Neo::Buttons::Base

      def initialize(
        label:,
        variant: :secondary,
        icon: nil,
        icon_position: :left,
        responsive: true,
        loading: false,
        disabled: false,
        confirm: nil,
        interactive: false,
        form: nil,
        url: nil,
        **options
      )
        @label = label
        @variant = variant.to_sym
        @size = :large
        @url = url
        @tag = url.present? ? :a : :button
        @loading = loading
        @disabled = disabled
        @confirm = confirm
        @interactive = interactive || loading || confirm.present?
        @icon = icon
        @icon_position = icon_position.to_sym
        @form = form
        @responsive = responsive
        @options = options
      end

      private

      def render_icon(position)
        return unless @icon && @icon_position == position

        margin = position == :left ? 'mr-2 max-sm:mr-0' : 'ml-2 max-sm:ml-0'
        content_tag(:i, '', class: "bi bi-#{@icon} #{margin}")
      end

      def label_classes
        @responsive ? 'hidden sm:inline' : ''
      end
    end
  end
end
