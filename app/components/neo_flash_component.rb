# frozen_string_literal: true

class NeoFlashComponent < ViewComponent::Base
  TYPES = {
    notice: { icon: 'check-circle-fill', color: 'green', icon_color: 'green' },
    success: { icon: 'check-circle-fill', color: 'green', icon_color: 'green' },
    alert: { icon: 'exclamation-triangle-fill', color: 'red', icon_color: 'red' },
    error: { icon: 'exclamation-triangle-fill', color: 'red', icon_color: 'red' },
    warning: { icon: 'exclamation-triangle-fill', color: 'yellow', icon_color: 'yellow' },
    info: { icon: 'info-circle-fill', color: 'cobalt', icon_color: 'cobalt' }
  }.freeze

  POSITIONS = {
    top_center: 'top-4 left-1/2 -translate-x-1/2',
    top_right: 'top-4 right-4',
    top_left: 'top-4 left-4',
    bottom_center: 'bottom-4 left-1/2 -translate-x-1/2',
    bottom_right: 'bottom-4 right-4',
    bottom_left: 'bottom-4 left-4'
  }.freeze

  def initialize(
    type: :notice,
    message: nil,
    dismissible: true,
    auto_hide: true,
    hide_delay: 2000,
    position: :top_center,
    turbo_frame: nil
  )
    @type = type.to_sym
    @message = message
    @dismissible = dismissible
    @auto_hide = auto_hide
    @hide_delay = hide_delay
    @position = position
    @turbo_frame = turbo_frame
  end

  def render?
    @message.present?
  end

  private

  def type_config
    TYPES[@type] || TYPES[:info]
  end

  def icon_name
    "bi-#{type_config[:icon]}"
  end

  def background_color
    case type_config[:color]
    when 'green'
      'bg-green-100'
    when 'red'
      'bg-red-100'
    when 'yellow'
      'bg-yellow-100'
    when 'cobalt'
      'bg-cobalt-100'
    else
      'bg-gray-100'
    end
  end

  def icon_color
    case type_config[:icon_color]
    when 'green'
      'text-green-700'
    when 'red'
      'text-red-700'
    when 'yellow'
      'text-yellow-700'
    when 'cobalt'
      'text-cobalt-700'
    else
      'text-gray-700'
    end
  end

  def position_classes
    POSITIONS[@position] || POSITIONS[:top_center]
  end

  def component_classes
    [
      'fixed',
      'z-toast',
      position_classes,
      'w-auto max-w-md',
      'shadow-sm',
      'rounded',
      'border border-slate-200',
      'transition-opacity duration-300 ease-out motion-reduce:transition-none',
      'overflow-hidden',
      background_color,
      'text-cream-900'
    ].join(' ')
  end
end
