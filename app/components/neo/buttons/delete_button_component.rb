# frozen_string_literal: true

module Neo
  module Buttons
    class DeleteButtonComponent < ViewComponent::Base
      def initialize(
        href:,
        size: :medium,
        icon_only: true,
        confirm: I18n.t('components.neo.buttons.delete_button.confirm'),
        method: :delete,
        **options
      )
        @href = href
        @size = size
        @icon_only = icon_only
        @confirm = confirm
        @method = method
        @options = options
      end

      def call
        shared_opts = {
          variant: :danger,
          size: @size,
          title: @options[:title] || I18n.t('components.neo.buttons.delete_button.title'),
          confirm: @confirm
        }

        if @icon_only
          if @options[:form]
            render Neo::Buttons::IconButtonComponent.new(
              icon: 'trash',
              form: @options[:form],
              **shared_opts,
              **@options.except(:title, :form)
            )
          else
            render Neo::Buttons::IconButtonComponent.new(
              icon: 'trash',
              interactive: true,
              tag: :a,
              href: @href,
              data: { turbo_method: @method, **(@options[:data] || {}) },
              **shared_opts,
              **@options.except(:title, :data)
            )
          end
        elsif @options[:form]
          render Neo::Buttons::ButtonComponent.new(
            icon: 'trash',
            form: @options[:form],
            **shared_opts,
            **@options.except(:title, :form)
          ) { content }
        else
          render Neo::Buttons::ButtonComponent.new(
            icon: 'trash',
            interactive: true,
            tag: :a,
            href: @href,
            data: { turbo_method: @method, **(@options[:data] || {}) },
            **shared_opts,
            **@options.except(:title, :data)
          ) { content }
        end
      end
    end
  end
end
