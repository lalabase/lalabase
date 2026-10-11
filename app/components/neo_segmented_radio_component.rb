# frozen_string_literal: true

class NeoSegmentedRadioComponent < ViewComponent::Base
  def initialize(
    name:,
    options:,
    selected: nil,
    size: :medium,
    with_shadow: false,
    interactive: true,
    **html_options
  )
    @name = name
    @options = options # Array of [label, value, icon] or [label, value]
    @selected = selected
    @size = size.to_sym
    @with_shadow = with_shadow
    @interactive = interactive
    @html_options = html_options
  end

  private

  def container_classes
    classes = ['radio-segmented inline-flex items-center rounded-full justify-start']
    classes << 'shadow-sm' if @with_shadow
    classes.join(' ')
  end

  def label_classes
    base_classes = [
      'relative inline-flex flex-row items-center justify-center gap-x-2',
      'tracking-[.00714em] font-medium border border-cream-300 bg-cream-50 cursor-pointer',
      # Segmented layout: overlap borders, fully rounded outer ends (stadium shape)
      'transition-all duration-200 -ml-px first:ml-0 first:rounded-l-full first:pl-5 last:rounded-r-full last:pr-5',
      # Checked state (via :has): active = warm fill + ink border + bold
      # (Teil G/G4: NOT lime, but NO dark block, too heavy as a permanent element)
      'has-[input:checked]:bg-cream-200 has-[input:checked]:text-cream-900 has-[input:checked]:border-ink has-[input:checked]:font-semibold has-[input:checked]:z-[2] has-[input:checked]:relative',
      # Hover state (unchecked only)
      'hover:bg-cream-100 hover:z-[1] hover:relative',
      'has-[input:checked]:hover:bg-cream-200'
    ]

    # Size-specific classes
    base_classes << case @size
                    when :small
                      'h-6 py-1 px-3 text-xs'
                    when :large
                      'h-10 py-3 px-5 text-base'
                    else # :medium
                      'h-8 py-2 px-4 text-sm'
                    end

    base_classes.join(' ')
  end

  def input_attributes(value)
    attrs = {
      type: 'radio',
      name: @name,
      value: value,
      class: 'z-10 opacity-0 absolute inset-0'
    }

    attrs[:checked] = true if @selected.to_s == value.to_s

    attrs[:data] = @html_options[:data] if @interactive && @html_options[:data]

    attrs
  end

  def unique_id(value)
    "#{@name}_#{value.to_s.parameterize.underscore}"
  end
end
