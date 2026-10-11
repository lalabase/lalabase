# frozen_string_literal: true

class NeoInfoTagComponent < ViewComponent::Base
  VARIANTS = {
    success: {
      bg: 'bg-green-100',
      text: 'text-green-900',
      border: 'border-green-900',
      icon_default: 'check-circle-fill'
    },
    warning: {
      bg: 'bg-yellow-200',
      text: 'text-yellow-900',
      border: 'border-stroke',
      icon_default: 'exclamation-triangle-fill'
    },
    danger: {
      bg: 'bg-red-100',
      text: 'text-red-900',
      border: 'border-red-900',
      icon_default: 'x-circle-fill'
    },
    info: {
      bg: 'bg-blue-100',
      text: 'text-blue-900',
      border: 'border-blue-900',
      icon_default: 'info-circle-fill'
    },
    processing: {
      bg: 'bg-yellow-200',
      text: 'text-yellow-800',
      border: 'border-stroke',
      icon_default: 'clock-fill'
    },
    neutral: {
      bg: 'bg-gray-100',
      text: 'text-gray-800',
      border: 'border-gray-400',
      icon_default: 'circle-fill'
    }
  }.freeze

  SIZES = {
    small: 'text-xs px-2.5 py-1',
    medium: 'text-sm px-3 py-1.5',
    large: 'text-base px-4 py-2'
  }.freeze

  def initialize(
    text:,
    variant: :info,
    size: :small,
    icon: nil,
    title: nil,
    animated: false,
    **options
  )
    @text = text
    @variant = variant.to_sym
    @size = size.to_sym
    @icon = icon || VARIANTS[@variant][:icon_default]
    @title = title
    @animated = animated
    @options = options
  end

  private

  def component_classes
    variant_config = VARIANTS[@variant]

    [
      base_classes,
      SIZES[@size],
      variant_config[:bg],
      variant_config[:text],
      variant_config[:border],
      @options[:class]
    ].compact.join(' ')
  end

  def component_attributes
    attrs = @options.except(:class).dup
    attrs[:title] = @title if @title
    attrs
  end

  def base_classes
    'inline-flex items-center gap-x-1.5 rounded-full font-medium border'
  end

  def render_icon
    return unless @icon

    icon_classes = ['bi', "bi-#{@icon}"]
    # The sign names its own box. It turns today without one, because the tag is a flex
    # container and blockifies it; as an inline box anywhere else it would stand still.
    icon_classes.push('inline-block', 'animate-spin') if @animated && @variant == :processing

    content_tag(:i, '', class: icon_classes.join(' '))
  end
end
