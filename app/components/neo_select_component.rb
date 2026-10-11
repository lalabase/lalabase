# frozen_string_literal: true

class NeoSelectComponent < ViewComponent::Base
  def initialize(
    name:,
    options:,
    label:, selected: nil,
    description: nil,
    disabled: false,
    size: :medium,
    required: false,
    placeholder: nil,
    interactive: true,
    **html_options
  )
    @name = name
    @options = options
    @selected = selected
    @label = label
    @description = description
    @disabled = disabled
    @size = size.to_sym
    @required = required
    @placeholder = placeholder
    @interactive = interactive
    @html_options = html_options
  end

  private

  def component_classes
    [
      base_classes,
      size_classes,
      state_classes,
      @html_options[:class]
    ].compact.join(' ')
  end

  def component_attributes
    attrs = @html_options.except(:class).dup
    attrs[:name] = @name
    attrs[:id] = select_id
    attrs[:disabled] = true if @disabled
    attrs[:required] = true if @required

    if @interactive
      attrs[:data] ||= {}
      attrs[:data].merge!(
        controller: 'neo-select',
        action: 'change->neo-select#handleChange'
      )
    end

    attrs
  end

  def base_classes
    'neo-select block w-full px-3 py-2 border border-slate-200 rounded bg-surface-raised transition-all duration-200 focus:outline-none focus:ring-2 focus:ring-black focus:border-stroke appearance-none'
  end

  def size_classes
    {
      small: 'text-xs h-8',
      medium: 'text-sm h-10',
      large: 'text-base h-12'
    }[@size] || 'text-sm h-10'
  end

  def state_classes
    if @disabled
      'opacity-50 cursor-not-allowed bg-gray-50'
    else
      'cursor-pointer shadow-sm hover:shadow-sm hover:-translate-x-0.5 hover:-translate-y-0.5 focus:shadow-sm focus:-translate-x-0.5 focus:-translate-y-0.5'
    end
  end

  def select_id
    @select_id ||= @html_options[:id] || "select_#{@name.to_s.gsub(/[\[\]]/, '_').gsub(/[^a-zA-Z0-9_]/, '_')}"
  end

  def wrapper_classes
    'neo-select-wrapper flex flex-col gap-1'
  end

  def label_classes
    [
      'neo-select-label text-sm font-medium text-gray-900',
      @required ? 'after:content-["*"] after:text-red-500 after:ml-1' : '',
      @disabled ? 'opacity-50' : ''
    ].compact.join(' ')
  end

  def description_classes
    'text-xs text-gray-600'
  end

  # Convert various option formats to [text, value] pairs
  def normalized_options
    case @options
    when Hash
      @options.map { |text, value| [text.to_s, value.to_s] }
    when Array
      @options.map do |option|
        case option
        when Array
          [option[0].to_s, option[1].to_s]
        when Hash
          [option[:text] || option['text'], option[:value] || option['value']]
        else
          [option.to_s, option.to_s]
        end
      end
    else
      []
    end
  end

  def option_selected?(value)
    return false if @selected.nil?

    @selected.to_s == value.to_s
  end

  def placeholder_option?
    @placeholder.present?
  end
end
