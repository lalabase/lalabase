# frozen_string_literal: true

# Concern for models that support custom attributes
# Provides methods for managing dynamic attributes with validation
module CustomAttributable
  extend ActiveSupport::Concern

  included do
    # Ensure custom_attributes is always a hash
    after_initialize :ensure_custom_attributes

    # Validate custom attributes before save
    validate :validate_custom_attributes, unless: :skip_custom_attribute_validation

    # Flag to skip custom attribute validation (e.g. Kanban single-attribute updates)
    attr_accessor :skip_custom_attribute_validation
  end

  # Cache invalidation on direct writes to custom_attributes
  def custom_attributes=(value)
    @_system_functions_resolver = nil
    super
  end

  # Get a custom attribute value
  def get_custom_attribute(name)
    custom_attributes[name.to_s]
  end

  # Set a custom attribute value
  def set_custom_attribute(name, value)
    self.custom_attributes = custom_attributes.merge(name.to_s => value)
  end

  # Bulk set custom attributes
  def set_custom_attributes(attributes_hash)
    self.custom_attributes = custom_attributes.merge(attributes_hash.stringify_keys)
  end

  # System functions delegation
  # Enables: ticket.has_system_function?('high_priority') → true/false
  # See SystemFunctions::Registry for available functions.
  def system_functions_resolver
    @_system_functions_resolver ||= SystemFunctions::Resolver.new(self)
  end

  def has_system_function?(key)
    system_functions_resolver.has?(key)
  end

  def active_system_functions
    system_functions_resolver.active_functions
  end

  # Get all attribute definitions for this record
  def attribute_definitions
    return @attribute_definitions if defined?(@attribute_definitions) && @attribute_definitions

    # For tickets, get attributes directly from project
    @attribute_definitions = if respond_to?(:project) && project
                               if project.association(:ticket_attribute_definitions).loaded?
                                 project.ticket_attribute_definitions.select(&:active?).sort_by(&:position)
                               else
                                 project.ticket_attribute_definitions.active.ordered
                               end
                             else
                               []
                             end

    @attribute_definitions
  end

  # Get visible attribute definitions for this record
  def visible_attribute_definitions
    attribute_definitions.select { |attr| attr.visible_for?(self) }
  end

  # Get required attribute definitions for this record
  def required_attribute_definitions
    visible_attribute_definitions.select { |attr| attr.required_for?(self) }
  end

  # Check if all required attributes are present
  def has_required_attributes?
    required_attribute_definitions.all? do |attr_def|
      get_custom_attribute(attr_def.name).present?
    end
  end

  # Get display value for a custom attribute
  def display_custom_attribute(name, locale = I18n.locale)
    attr_def = attribute_definitions.find { |ad| ad.name == name.to_s }
    return nil unless attr_def

    value = get_custom_attribute(name)
    attr_def.display_value(value, locale)
  end

  # Build a hash of all custom attributes with their display values
  def custom_attributes_display(locale = I18n.locale)
    visible_attribute_definitions.each_with_object({}) do |attr_def, hash|
      value = get_custom_attribute(attr_def.name)
      next if value.blank?

      hash[attr_def.label_for(locale)] = attr_def.display_value(value, locale)
    end
  end

  private

  def ensure_custom_attributes
    self.custom_attributes ||= {}
  end

  def validate_custom_attributes
    return unless custom_attributes_changed?

    visible_attribute_definitions.each do |attr_def|
      value = get_custom_attribute(attr_def.name)
      validation_errors = attr_def.validate_value(value, self)

      validation_errors.each do |error|
        errors.add(:base, "#{attr_def.label_for}: #{error}")
      end
    end
  end
end
