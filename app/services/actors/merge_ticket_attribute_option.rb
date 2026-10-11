# frozen_string_literal: true

# app/services/actors/merge_ticket_attribute_option.rb
#
# Tier-1 actor: merges a source option value into a target on a select/multiselect
# ticket attribute definition. It rewrites every ticket carrying the source value,
# then drops the source option from the definition. Moved here 1:1 from the former
# TicketAttributeDefinition#merge_option! (that model method is deleted — it had a
# single caller).
#
# Per-ticket writes go through update! DELIBERATELY: each keeps the audit/Trackable
# chain (F4 — one Activity per updated ticket is wanted). They set
# skip_custom_attribute_validation (F2, so a legacy-invalid NEIGHBOUR value cannot
# block the merge) and updater = current_user. The whole thing runs inside the
# BaseActor transaction, so a failure mid-batch rolls back every ticket AND the
# option removal. The ArgumentError guards of the old method become coded
# ActorErrors. #updated_count is exposed for the controller's flash — call via
# .new(...).call to read it after #call (documented BaseActor exception).
module Actors
  class MergeTicketAttributeOption < BaseActor
    ERROR_SCOPE = 'activerecord.errors.models.ticket_attribute_definition'

    attr_reader :updated_count

    def initialize(attribute_definition:, source_value:, target_value:, current_user:)
      super()
      @attribute_definition = attribute_definition
      @source_value = source_value
      @target_value = target_value
      @current_user = current_user
      @updated_count = 0
    end

    def record
      @attribute_definition
    end

    def perform
      validate_values!
      merge_tickets
      remove_source_option!
    end

    private

    def validate_values!
      raise ActorError.new(I18n.t("#{ERROR_SCOPE}.source_equals_target"), code: :source_equals_target) if @source_value == @target_value

      values = @attribute_definition.allowed_values.map { |v| v['value'] }
      raise ActorError.new(I18n.t("#{ERROR_SCOPE}.source_not_found", value: @source_value), code: :source_not_found) unless values.include?(@source_value)
      return if values.include?(@target_value)

      raise ActorError.new(I18n.t("#{ERROR_SCOPE}.target_not_found", value: @target_value), code: :target_not_found)
    end

    def merge_tickets
      attr_name = @attribute_definition.name

      case @attribute_definition.field_type
      when 'select'
        tickets_matching(attr_name => @source_value).find_each do |ticket|
          apply_merge(ticket, attr_name, @target_value)
        end
      when 'multiselect'
        tickets_matching(attr_name => [@source_value]).find_each do |ticket|
          current_values = ticket.custom_attributes[attr_name] || []
          apply_merge(ticket, attr_name, (current_values - [@source_value] + [@target_value]).uniq)
        end
      end
    end

    def tickets_matching(fragment)
      @attribute_definition.project.tickets.where('custom_attributes @> ?', fragment.to_json)
    end

    def apply_merge(ticket, attr_name, new_value)
      ticket.updater = @current_user
      ticket.skip_custom_attribute_validation = true
      ticket.update!(custom_attributes: ticket.custom_attributes.merge(attr_name => new_value))
      @updated_count += 1
    end

    def remove_source_option!
      new_allowed_values = @attribute_definition.options['allowed_values'].reject { |v| v['value'] == @source_value }
      @attribute_definition.update!(options: @attribute_definition.options.merge('allowed_values' => new_allowed_values))
    end
  end
end
