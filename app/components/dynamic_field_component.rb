# frozen_string_literal: true

# Component for rendering dynamic form fields based on attribute definitions
class DynamicFieldComponent < ViewComponent::Base
  attr_reader :form, :attribute_def, :value, :ticket

  def initialize(form:, attribute_definition:, ticket:, value: nil)
    @form = form
    @attribute_def = attribute_definition
    @ticket = ticket
    @value = value || ticket.get_custom_attribute(attribute_definition.name)
  end

  private

  def field_name
    "ticket[custom_attributes][#{attribute_def.name}]"
  end

  def field_id
    "ticket_custom_attributes_#{attribute_def.name}"
  end

  def label_text
    attribute_def.label_for(I18n.locale)
  end

  def required?
    attribute_def.required_for?(ticket)
  end

  def placeholder_text
    attribute_def.placeholder_for(I18n.locale)
  end

  def help_text
    attribute_def.help_text_for(I18n.locale)
  end

  def field_classes
    base_classes = 'w-full px-3 py-2 border border-stroke rounded-md '
    base_classes += 'focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-black '
    base_classes += 'hover:shadow-sm transition-all duration-200'
    base_classes
  end

  def render_field
    case attribute_def.field_type
    when 'text'
      render_text_field
    when 'textarea'
      render_textarea_field
    when 'number'
      render_number_field
    when 'currency'
      render_currency_field
    when 'percentage'
      render_percentage_field
    when 'date'
      render_date_field
    when 'datetime'
      render_datetime_field
    when 'select'
      render_select_field
    when 'multiselect'
      render_multiselect_field
    when 'radio'
      render_radio_field
    when 'checkbox'
      render_checkbox_field
    when 'email'
      render_email_field
    when 'phone'
      render_phone_field
    when 'url'
      render_url_field
    else
      render_text_field # fallback
    end
  end

  def render_text_field
    text_field_tag(
      field_name,
      value,
      id: field_id,
      class: field_classes,
      placeholder: placeholder_text,
      required: required?
    )
  end

  def render_textarea_field
    text_area_tag(
      field_name,
      value,
      id: field_id,
      class: field_classes,
      placeholder: placeholder_text,
      required: required?,
      rows: attribute_def.options['rows'] || 3
    )
  end

  def render_number_field
    number_field_tag(
      field_name,
      value,
      id: field_id,
      class: field_classes,
      placeholder: placeholder_text,
      required: required?,
      min: attribute_def.validation_rules['min'],
      max: attribute_def.validation_rules['max'],
      step: attribute_def.options['step'] || 1
    )
  end

  def render_currency_field
    content_tag(:div, class: 'relative') do
      content_tag(:span, '€', class: 'absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-500') +
        number_field_tag(
          field_name,
          value,
          id: field_id,
          class: field_classes + ' pl-8',
          placeholder: placeholder_text,
          required: required?,
          min: attribute_def.validation_rules['min'],
          max: attribute_def.validation_rules['max'],
          step: 0.01
        )
    end
  end

  def render_percentage_field
    content_tag(:div, class: 'relative') do
      number_field_tag(
        field_name,
        value,
        id: field_id,
        class: field_classes + ' pr-8',
        placeholder: placeholder_text,
        required: required?,
        min: attribute_def.validation_rules['min'] || 0,
        max: attribute_def.validation_rules['max'] || 100,
        step: attribute_def.options['step'] || 1
      ) +
        content_tag(:span, '%', class: 'absolute right-3 top-1/2 transform -translate-y-1/2 text-gray-500')
    end
  end

  def render_date_field
    date_field_tag(
      field_name,
      value,
      id: field_id,
      class: field_classes,
      required: required?
    )
  end

  def render_datetime_field
    datetime_field_tag(
      field_name,
      value,
      id: field_id,
      class: field_classes,
      required: required?
    )
  end

  def render_select_field
    options = attribute_def.allowed_values.map do |option|
      [
        option['labels'][I18n.locale.to_s] || option['value'],
        option['value']
      ]
    end

    select_tag(
      field_name,
      options_for_select(options, value),
      id: field_id,
      class: field_classes,
      required: required?,
      include_blank: !required?
    )
  end

  def render_multiselect_field
    options = attribute_def.allowed_values.map do |option|
      [
        option['labels'][I18n.locale.to_s] || option['value'],
        option['value']
      ]
    end

    select_tag(
      "#{field_name}[]",
      options_for_select(options, value || []),
      id: field_id,
      class: field_classes,
      required: required?,
      multiple: true,
      size: [attribute_def.options['size'] || 4, options.length].min
    )
  end

  def render_radio_field
    content_tag(:div, class: 'space-y-2') do
      attribute_def.allowed_values.map do |option|
        option_value = option['value']
        option_label = option['labels'][I18n.locale.to_s] || option_value
        radio_id = "#{field_id}_#{option_value}"

        content_tag(:label, class: 'flex items-center cursor-pointer') do
          radio_button_tag(
            field_name,
            option_value,
            value == option_value,
            id: radio_id,
            class: 'mr-2',
            required: required?
          ) +
            content_tag(:span, option_label)
        end
      end.join.html_safe
    end
  end

  def render_checkbox_field
    content_tag(:label, class: 'flex items-center cursor-pointer') do
      check_box_tag(
        field_name,
        '1',
        ['1', true].include?(value),
        id: field_id,
        class: 'mr-2'
      ) +
        content_tag(:span, label_text)
    end
  end

  def render_email_field
    email_field_tag(
      field_name,
      value,
      id: field_id,
      class: field_classes,
      placeholder: placeholder_text || 'email@example.com',
      required: required?
    )
  end

  def render_phone_field
    telephone_field_tag(
      field_name,
      value,
      id: field_id,
      class: field_classes,
      placeholder: placeholder_text || '+49 123 456789',
      required: required?
    )
  end

  def render_url_field
    url_field_tag(
      field_name,
      value,
      id: field_id,
      class: field_classes,
      placeholder: placeholder_text || 'https://example.com',
      required: required?
    )
  end
end
