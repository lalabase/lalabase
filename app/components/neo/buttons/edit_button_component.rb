# frozen_string_literal: true

module Neo
  module Buttons
    class EditButtonComponent < ViewComponent::Base
      def initialize(href:, size: :medium, icon_only: true, **options)
        @href = href
        @size = size
        @icon_only = icon_only
        @options = options
      end

      def call
        component_class = @icon_only ? Neo::Buttons::IconButtonComponent : Neo::Buttons::ButtonComponent
        render component_class.new(
          variant: :edit,
          size: @size,
          icon: 'pencil',
          title: @options[:title] || 'Bearbeiten',
          tag: :a,
          href: @href,
          **@options.except(:title)
        ) { content unless @icon_only }
      end
    end
  end
end
