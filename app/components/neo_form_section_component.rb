# frozen_string_literal: true

class NeoFormSectionComponent < ViewComponent::Base
  def initialize(
    title:,
    description: nil,
    expanded: true,
    collapsible: true,
    icon: nil,
    variant: :default,
    size: :medium,
    **options
  )
    @title = title
    @description = description
    @expanded = expanded
    @collapsible = collapsible
    @icon = icon
    @variant = variant.to_sym
    @size = size.to_sym
    @options = options
  end

  private

  def wrapper_classes
    [
      base_classes,
      variant_classes,
      size_classes,
      @options[:class]
    ].compact.join(' ')
  end

  def base_classes
    # Warm-Editorial (Part G): large content section → flat (cream-50 + 1px cream-300,
    # no shadow); separation via tone + line. Shadow stays reserved for focal cards.
    'neo-form-section border border-cream-300 rounded-lg bg-cream-50 transition-all duration-200'
  end

  def variant_classes
    {
      default: '',
      primary: 'bg-lime-50 border-lime-500',
      secondary: 'bg-cream-100 border-cream-300',
      warning: 'bg-yellow-50 border-yellow-500',
      danger: 'bg-red-50 border-red-500',
      success: 'bg-green-50 border-green-500'
    }[@variant] || ''
  end

  def size_classes
    {
      small: 'p-4',
      medium: 'p-6',
      large: 'p-8'
    }[@size] || 'p-6'
  end

  def header_classes
    [
      'neo-form-section-header flex items-center justify-between',
      @collapsible ? 'cursor-pointer hover:bg-cream-100 -m-2 p-2 rounded' : '',
      'transition-colors duration-200'
    ].compact.join(' ')
  end

  def title_classes
    [
      'neo-form-section-title font-bold text-cream-900',
      title_size_classes
    ].join(' ')
  end

  def title_size_classes
    case @size
    when :small
      'text-base'
    when :large
      'text-xl'
    else
      'text-lg'
    end
  end

  def description_classes
    'neo-form-section-description text-sm text-cream-600 mt-1'
  end

  def content_classes
    [
      'neo-form-section-content',
      @expanded ? 'block' : 'hidden',
      'mt-4 transition-all duration-200'
    ].join(' ')
  end

  def section_id
    @section_id ||= @options[:id] || "section_#{@title.to_s.parameterize.underscore}"
  end

  def collapse_icon
    if @expanded
      'bi-chevron-up'
    else
      'bi-chevron-down'
    end
  end

  def render_icon
    return unless @icon

    "<i class=\"bi bi-#{@icon} mr-2 text-lg\"></i>".html_safe
  end

  def data_attributes
    {
      controller: 'neo-form-section',
      neo_form_section_expanded_value: @expanded,
      neo_form_section_collapsible_value: @collapsible
    }
  end

  def content_data_attributes
    {
      neo_form_section_target: 'content'
    }
  end

  def chevron_data_attributes
    {
      neo_form_section_target: 'chevron'
    }
  end
end
