# frozen_string_literal: true

module Organisations
  class TicketAttributeDefinitionsController < Organisations::BaseController
    include ProjectController

    skip_before_action :authorize_project_access!
    before_action :set_attribute_definition, only: %i[edit update destroy toggle_active merge_option execute_merge]
    before_action :authorize_manage_attributes!

    # Attributes are authorized via Project (authorize), not via policy_scope
    skip_after_action :verify_policy_scoped, only: [:index]

    def index
      @active_attributes = @project.ticket_attribute_definitions.where(active: true).ordered
      @inactive_attributes = @project.ticket_attribute_definitions.where(active: false).ordered
    end

    def new
      @attribute_definition = @project.ticket_attribute_definitions.build
      @all_attributes = @project.ticket_attribute_definitions.ordered
    end

    def create
      @attribute_definition = @project.ticket_attribute_definitions.build(attribute_definition_params)

      if @attribute_definition.save
        redirect_to organisation_project_ticket_attribute_definitions_path(@current_organisation, @project),
                    notice: t('flash.ticket_attribute_definitions.created')
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      load_option_usage_counts
      @all_attributes = @project.ticket_attribute_definitions.ordered
    end

    def update
      if @attribute_definition.update(attribute_definition_params)
        redirect_to organisation_project_ticket_attribute_definitions_path(@current_organisation, @project),
                    notice: t('flash.ticket_attribute_definitions.updated')
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @attribute_definition.destroy

      redirect_to organisation_project_ticket_attribute_definitions_path(@current_organisation, @project),
                  notice: t('flash.ticket_attribute_definitions.deleted')
    end

    def sort
      ids = params[:ids]
      return head :bad_request unless ids.is_a?(Array)

      Actors::SortTicketAttributeDefinitions.call(project: @project, ordered_ids: ids, current_user: current_user)

      head :ok
    end

    def merge_option
      @source_value = params[:source_value]

      values = @attribute_definition.allowed_values.map { |v| v['value'] }
      unless values.include?(@source_value)
        redirect_to organisation_project_ticket_attribute_definitions_path(@current_organisation, @project),
                    alert: t('flash.ticket_attribute_definitions.option_not_found')
        return
      end

      @source_option = @attribute_definition.allowed_values.find { |v| v['value'] == @source_value }
      @target_options = @attribute_definition.allowed_values.reject { |v| v['value'] == @source_value }
      @affected_count = count_affected_tickets(@source_value)
    end

    def execute_merge
      source_value = params[:source_value]
      target_value = params[:target_value]

      # .new(...).call so we can read #updated_count for the flash after the call
      # (the actor exposes the count without touching the Result contract).
      actor = Actors::MergeTicketAttributeOption.new(
        attribute_definition: @attribute_definition,
        source_value: source_value,
        target_value: target_value,
        current_user: current_user
      )
      result = actor.call

      if result.success?
        redirect_to organisation_project_ticket_attribute_definitions_path(@current_organisation, @project),
                    notice: t('flash.ticket_attribute_definitions.options_merged', source: source_value, target: target_value, count: actor.updated_count, tickets: 'Ticket'.pluralize(actor.updated_count, I18n.locale))
      else
        redirect_to organisation_project_ticket_attribute_definitions_path(@current_organisation, @project),
                    alert: result.errors.first
      end
    end

    def toggle_active
      @attribute_definition.update!(active: !@attribute_definition.active?)
      redirect_to organisation_project_ticket_attribute_definitions_path(@current_organisation, @project),
                  notice: @attribute_definition.active? ? t('flash.ticket_attribute_definitions.activated') : t('flash.ticket_attribute_definitions.deactivated')
    end

    private

    def set_attribute_definition
      @attribute_definition = @project.ticket_attribute_definitions.find(params[:id])
    end

    def load_option_usage_counts
      return unless %w[select multiselect].include?(@attribute_definition.field_type)

      attr_name = @attribute_definition.name
      @option_usage_counts = @project.tickets
                                     .where('custom_attributes ? :key', key: attr_name)
                                     .group(Arel.sql("custom_attributes->>'#{ActiveRecord::Base.connection.quote_string(attr_name)}'"))
                                     .count
    end

    def attribute_definition_params
      permitted = params.require(:ticket_attribute_definition).permit(
        :field_type, :section, :width, :position, :active,
        labels: {}, validation_rules: {}, visibility_rules: {},
        options: [], option_colors: []
      )

      # Extract the arrays for options processing
      options_array = permitted.delete(:options) || []
      colors_array = permitted.delete(:option_colors) || []

      # System functions: hash with array values ({ "0" => ["high_priority"], ... })
      # cannot be permitted via standard strong parameters → extract manually, as
      # index => list of strings. The model validates each key against the registry.
      raw_sf = params.dig(:ticket_attribute_definition, :option_system_functions)
      system_functions_hash = if raw_sf.is_a?(ActionController::Parameters)
                                raw_sf.keys.index_with { |key| Array.wrap(raw_sf[key]).map(&:to_s) }
                              else
                                {}
                              end

      # Convert options array to proper structure if needed
      if options_array.is_a?(Array) && %w[select multiselect].include?(permitted[:field_type])
        valid_options = options_array.reject(&:blank?)
        # Preserve configured signal-bar levels across edits: the option editor does not (yet)
        # expose a level input, so without this an unrelated edit (rename, recolor) would strip
        # the levels and the priority bars would vanish. Matched by option value.
        preserved_levels = existing_option_levels

        permitted[:options] = if valid_options.any?
                                {
                                  'allowed_values' => valid_options.map.with_index do |value, index|
                                    functions = (system_functions_hash[index.to_s] || []).reject(&:blank?)

                                    entry = {
                                      'value' => value,
                                      'labels' => { 'de' => value, 'en' => value },
                                      'color' => normalized_option_color(colors_array[index])
                                    }
                                    entry['system_functions'] = functions if functions.any?
                                    entry['level'] = preserved_levels[value] if preserved_levels.key?(value)
                                    entry
                                  end
                                }
                              else
                                {}
                              end
      elsif permitted[:field_type] == 'date'
        # Deadline marker: only overwrite options when the checkbox is actually submitted, so
        # editing a date field without the checkbox present cannot silently drop the marker.
        if params[:ticket_attribute_definition].key?(:deadline)
          marked = ActiveModel::Type::Boolean.new.cast(params.dig(:ticket_attribute_definition, :deadline)) == true
          permitted[:options] = marked ? { TicketAttributeDefinition::DEADLINE_OPTION_KEY => true } : {}
        end
      else
        permitted[:options] = {}
      end

      permitted
    end

    # The form posts an <input type="color">, which can only send a hex value; anything
    # else comes from a hand-made request and is replaced silently, like a missing colour.
    # The model validates the same format, this keeps the form from failing on it.
    def normalized_option_color(raw)
      TicketAttributeDefinition.safe_option_color(raw.to_s.strip,
                                                  TicketAttributeDefinition::OPTION_COLOR_FALLBACK)
    end

    # Existing option value => configured level, read from the persisted record (during update
    # @attribute_definition still holds the old options). Empty for new records.
    def existing_option_levels
      (@attribute_definition&.allowed_values || []).each_with_object({}) do |option, acc|
        acc[option['value']] = option['level'] unless option['level'].nil?
      end
    end

    def count_affected_tickets(value)
      attr_name = @attribute_definition.name
      case @attribute_definition.field_type
      when 'select'
        @project.tickets.where('custom_attributes @> ?', { attr_name => value }.to_json).count
      when 'multiselect'
        @project.tickets.where('custom_attributes @> ?', { attr_name => [value] }.to_json).count
      else
        0
      end
    end

    def authorize_manage_attributes!
      authorize @project, :manage?, policy_class: TicketAttributeDefinitionPolicy
    end
  end
end
