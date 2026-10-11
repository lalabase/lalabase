# frozen_string_literal: true

module Neo
  module Buttons
    class ShowButtonComponent < ViewComponent::Base
      def initialize(href:, size: :medium, icon_only: true, **options)
        @href = href
        @size = size
        @icon_only = icon_only
        @options = options
      end

      def call
        component_class = @icon_only ? Neo::Buttons::IconButtonComponent : Neo::Buttons::ButtonComponent
        render component_class.new(
          variant: :secondary,
          size: @size,
          icon: 'eye',
          title: @options[:title] || 'Details anzeigen',
          tag: :a,
          href: @href,
          **@options.except(:title)
        ) { content unless @icon_only }
      end
    end
  end
end
