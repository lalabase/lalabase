# frozen_string_literal: true

class NeoToggleComponent < ViewComponent::Base
  def initialize(
    name:,
    label:,
    checked: false,
    description: nil,
    disabled: false,
    size: :medium,
    interactive: true,
    **options
  )
    @name = name
    @checked = checked
    @label = label
    @description = description
    @disabled = disabled
    @size = size.to_sym
    @interactive = interactive
    @options = options
  end

  private

  def component_attributes
    attrs = @options.except(:class).dup
    attrs[:name] = @name
    attrs[:value] = '1'
    attrs[:type] = 'checkbox'
    attrs[:checked] = @checked if @checked
    attrs[:disabled] = true if @disabled
    attrs[:id] = toggle_id

    if @interactive
      attrs[:data] ||= {}
      attrs[:data].merge!(
        controller: 'neo-toggle',
        action: 'change->neo-toggle#toggle'
      )
    end

    attrs
  end

  def toggle_id
    @toggle_id ||= @options[:id] || "toggle_#{@name.to_s.gsub(/[\[\]]/, '_').gsub(/[^a-zA-Z0-9_]/, '_')}"
  end

  def wrapper_classes
    base_classes = 'neo-toggle-wrapper flex items-center gap-3'
    @disabled ? "#{base_classes} opacity-60" : base_classes
  end

  def toggle_track_classes
    # Base classes for the toggle track
    base_classes = [
      'relative inline-flex items-center rounded-full border border-slate-200 transition-all duration-200',
      'focus-within:outline-none focus-within:ring-2 focus-within:ring-offset-2 focus-within:ring-black'
    ]

    # Size-specific classes
    size_classes = case @size
                   when :small then %w[h-5 w-9]
                   when :large then %w[h-7 w-12]
                   else %w[h-6 w-11]
                   end

    # State-dependent background and shadow
    if @checked
      background_classes = ['bg-cobalt-600']
      shadow_classes = ['shadow-sm']
    else
      background_classes = ['bg-gray-100']
      shadow_classes = []
    end

    # Hover effects (only if not disabled)
    hover_classes = []
    unless @disabled
      hover_classes = if @checked
                        [
                          'hover:bg-cobalt-700',
                          'hover:shadow-sm',
                          'hover:-translate-x-[1px]',
                          'hover:-translate-y-[1px]'
                        ]
                      else
                        [
                          'hover:bg-gray-300',
                          'hover:shadow-sm',
                          'hover:-translate-x-[1px]',
                          'hover:-translate-y-[1px]'
                        ]
                      end
    end

    # Cursor
    cursor_classes = @disabled ? %w[cursor-not-allowed opacity-50] : ['cursor-pointer']

    # Combine all classes
    (base_classes + size_classes + background_classes + shadow_classes + hover_classes + cursor_classes).join(' ')
  end

  def toggle_thumb_classes
    # Base classes for the thumb
    base_classes = [
      'pointer-events-none inline-block transform rounded-full border border-stroke bg-surface-raised shadow-sm transition-transform duration-200'
    ]

    # Size-dependent thumb size
    size_classes = case @size
                   when :small then %w[h-3 w-3]
                   when :large then %w[h-5 w-5]
                   else %w[h-4 w-4]
                   end

    # Position based on checked state and size
    position_classes = if @checked
                         case @size
                         when :small then ['translate-x-4']  # Small: move right 16px (4 * 4px)
                         when :large then ['translate-x-6']  # Large: move right 24px (6 * 4px)
                         else ['translate-x-5'] # Medium: move right 20px (5 * 4px)
                         end
                       else
                         ['translate-x-0.5'] # All sizes: slight offset from left edge
                       end

    # Combine all classes
    (base_classes + size_classes + position_classes).join(' ')
  end

  def label_text_classes
    base = 'neo-toggle-label text-sm font-medium text-gray-900 cursor-pointer'
    @disabled ? "#{base} text-gray-500" : base
  end

  def description_classes
    base = 'text-xs text-gray-600 mt-0.5'
    @disabled ? "#{base} text-gray-400" : base
  end

  def hidden_input_attributes
    {
      type: 'hidden',
      name: @name,
      value: '0'
    }
  end

  # Inline styles to ensure proper positioning regardless of Tailwind build.
  # The "on" colour lives in three places that must agree: the track class above,
  # this inline style, and neo_toggle_controller.js#updateToggleVisuals. Inline wins
  # over the class in the browser, so a change to the class alone is invisible.
  def track_inline_styles
    if @checked
      'background-color: rgb(var(--cobalt-600)); box-shadow: 2px 2px 0 0 #000000;'
    else
      'background-color: #e5e7eb;'
    end
  end

  def thumb_inline_styles
    # Calculate transform based on size and state
    translate_x = if @checked
                    case @size
                    when :small then '16px'    # translate-x-4
                    when :large then '24px'    # translate-x-6
                    else '20px'                # translate-x-5 (medium)
                    end
                  else
                    '2px'                      # translate-x-0.5
                  end

    "transform: translateX(#{translate_x}); transition: transform 0.2s ease-in-out;"
  end
end
