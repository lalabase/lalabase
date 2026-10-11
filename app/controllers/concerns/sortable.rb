# frozen_string_literal: true

# app/controllers/concerns/sortable.rb
module Sortable
  extend ActiveSupport::Concern

  included do
    class_attribute :default_sort_column
    class_attribute :sortable_model_class
    class_attribute :model_table_name
    class_attribute :related_sortable_columns
    class_attribute :related_models
    class_attribute :sortable_columns_list

    helper_method :sort_column, :sort_direction, :sort_params
  end

  # Class that can be called during initialization
  module ClassMethods
    # Setup for Sortable with automatic column detection
    def setup_sortable(model_class, default_column = nil, prefixed = true)
      self.sortable_model_class = model_class
      self.model_table_name = model_class.table_name
      self.related_sortable_columns = []
      self.related_models = {}

      # Determine the default column automatically (created_at if available, otherwise id)
      table_prefix = prefixed ? "#{model_table_name}." : ''
      self.default_sort_column = default_column || "#{table_prefix}created_at"

      # Determine sortable columns automatically from the model and ensure that both
      # qualified and unqualified column names are supported (for backward compatibility)
      column_set = model_class.column_names
      if prefixed
        # Add both qualified and unqualified column names for backward compatibility
        qualified_columns = column_set.map { |col| "#{model_table_name}.#{col}" }
        self.sortable_columns_list = column_set + qualified_columns
      else
        self.sortable_columns_list = column_set
      end
    end

    # Add additional custom columns to the sorting
    def add_sortable_columns(*columns)
      self.sortable_columns_list = (sortable_columns_list || []) + columns
      self.related_sortable_columns ||= []
      self.related_sortable_columns += columns
    end

    # Add columns from related models
    def add_related_sortable_columns(related_table, *columns)
      # If a hash syntax is used for related_sortable_columns
      if related_table.is_a?(Hash) && columns.empty?
        # Store the entire mapping for later
        self.related_sortable_columns ||= []
        related_sortable_columns << related_table

        related_table.each do |qual_column, alias_name|
          table_name, = qual_column.to_s.split('.')

          # Try to find the associated model class
          related_model = find_model_for_table(table_name)

          if related_model
            self.related_models ||= {}
            related_models[table_name] = related_model
          end

          # Add a mapping between the alias and the actual column name
          add_sortable_columns(alias_name.to_s)
        end
      else
        # Try to find the associated model class
        related_model = find_model_for_table(related_table)

        if related_model
          self.related_models ||= {}
          related_models[related_table] = related_model
        end

        qualified_columns = columns.map { |col| "#{related_table}.#{col}" }
        add_sortable_columns(*qualified_columns)
      end
    end

    # Finds the matching model for a table
    def find_model_for_table(table_name)
      # Cache for found models
      @model_cache ||= {}
      return @model_cache[table_name] if @model_cache.key?(table_name)

      model = nil

      # Try to find the model based on the table name
      # Most Rails models use conventions
      begin
        # For pluralized table names (default)
        potential_model = table_name.singularize.camelize.constantize
        model = potential_model if potential_model.respond_to?(:table_name) && potential_model.table_name == table_name
      rescue NameError
        # Ignore if the class does not exist
      end

      # Special cases for known tables
      if model.nil?
        model = case table_name
                when 'ticket_statuses'
                  TicketStatus if defined?(TicketStatus)
                when 'ticket_priorities'
                  TicketPriority if defined?(TicketPriority)
                when 'projects'
                  Project if defined?(Project)
                when 'users'
                  User if defined?(User)
                when 'organisations', 'organizations'
                  Organisation if defined?(Organisation)
                else
                  # As a last attempt: search through already-loaded models
                  if defined?(ApplicationRecord) && ApplicationRecord.respond_to?(:descendants)
                    ApplicationRecord.descendants.find do |m|
                      m.respond_to?(:table_name) && m.table_name == table_name
                    end
                  end
                end
      end

      @model_cache[table_name] = model
      model
    end
  end

  # Helper method to obtain the model class
  def model_class
    self.class.sortable_model_class
  end

  # Returns the current sort column or the default
  def sort_column
    # Support both Hash format { column: "...", direction: "..." } and plain string
    sort_param = params[:sort]
    if sort_param.is_a?(Hash) || sort_param.is_a?(ActionController::Parameters)
      return default_sort_column unless sort_param[:column].present?

      column = sort_param[:column].to_s
    elsif sort_param.is_a?(String) || sort_param.is_a?(Symbol)
      return default_sort_column if sort_param.blank?

      column = sort_param.to_s
    else
      return default_sort_column
    end

    # Check whether it is an alias and map it to the real column
    if self.class.related_sortable_columns.present?
      # Look for the alias in related_sortable_columns
      self.class.related_sortable_columns.each do |mapping|
        next unless mapping.is_a?(Hash)

        mapping.each do |real_column, alias_name|
          return real_column.to_s if alias_name.to_s == column
        end
      end
    end

    # Validate the column against the whitelist
    is_valid_sort_column?(column) ? column : default_sort_column
  end

  # Returns the current sort direction
  def sort_direction
    # Support both Hash format and separate :direction param
    sort_param = params[:sort]
    if sort_param.is_a?(Hash) || sort_param.is_a?(ActionController::Parameters)
      direction = sort_param[:direction]&.to_s&.downcase
    elsif params[:direction].present?
      direction = params[:direction].to_s.downcase
    end

    direction = nil if direction.blank?
    %w[asc desc].include?(direction) ? direction : 'desc'
  end

  # Forwards sort parameters to links
  def sort_params
    # Basic sort parameters
    result = { sort: { column: sort_column, direction: sort_direction } }

    # Keep ALL important context parameters
    # SmartFolder ID first (highest priority)
    result[:smart_folder_id] = params[:smart_folder_id] if params[:smart_folder_id].present?

    # Add the project ID only if we are NOT in the tickets controller
    # (for tickets the project_id is already in the URL path)
    result[:project_id] = params[:project_id] if params[:project_id].present? && controller_name != 'tickets'

    # Keep the search parameter
    result[:search] = params[:search] if params[:search].present?

    # Keep the filter parameter (as a plain hash, so that .to_query works)
    result[:filter] = params[:filter].to_unsafe_h if params[:filter].present?

    # Keep the context type (for SmartFolder)
    result[:context_type] = params[:context_type] if params[:context_type].present?

    result
  end

  # Finds the model for a table
  def find_model_for_table(table_name)
    # First look in the registered models
    return self.class.related_models[table_name] if self.class.related_models && self.class.related_models[table_name]

    # Otherwise use the class method
    self.class.find_model_for_table(table_name)
  end

  # Determines the type of a column from a model
  def get_column_type(model_class, column_name)
    return nil unless model_class.respond_to?(:columns_hash) && model_class.columns_hash[column_name]

    model_class.columns_hash[column_name].type
  end

  # Checks whether a column is of type text or string
  def is_text_column?(model_class, column_name)
    column_type = get_column_type(model_class, column_name)
    column_type && %i[string text].include?(column_type)
  end

  # Applies sorting to a query
  def apply_sorting(query)
    # Debug output to see how sorting is applied
    column_name = sort_column

    if column_name.include?('.')
      table_name, column_without_table = column_name.split('.')
      target_model = find_model_for_table(table_name)
    else
      column_without_table = column_name
      table_name = model_table_name
      target_model = model_class
    end

    # Ensure that to_sql can be called safely
    has_distinct = false
    begin
      has_distinct = query.to_sql.upcase.include?('DISTINCT') if query.respond_to?(:to_sql)
    rescue StandardError => e
      Rails.logger.error "Error accessing to_sql: #{e.message}"
    end

    # Check whether it is a text column
    is_text_column = target_model && is_text_column?(target_model, column_without_table)

    if has_distinct
      # For DISTINCT we have to use a different strategy

      # 1. Create a copy of the query without any ORDER BY
      clean_query = query.except(:order)

      # When sorting by columns from joined tables, ensure that
      # the outer query has access to those tables
      # Detect which tables are used in the sorting
      final_query = if column_name.include?('.') && table_name != model_table_name
                      case table_name
                      when 'tickets'
                        # Specific JOIN for Tickets in DISTINCT queries
                        model_class.select('time_sessions.*')
                                   .from(clean_query, model_table_name)
                                   .joins("LEFT OUTER JOIN tickets ON tickets.id = #{model_table_name}.ticket_id")
                      when 'users'
                        # Specific JOIN for Users in DISTINCT queries
                        model_class.select('time_sessions.*')
                                   .from(clean_query, model_table_name)
                                   .joins("LEFT OUTER JOIN users ON users.id = #{model_table_name}.creator_id")
                      when 'projects'
                        # Specific JOIN for Projects in DISTINCT queries
                        model_class.select('time_sessions.*')
                                   .from(clean_query, model_table_name)
                                   .joins("LEFT OUTER JOIN projects ON projects.id = #{model_table_name}.project_id")
                      else
                        # Fallback when no specific JOIN condition is defined
                        model_class.from(clean_query, model_table_name)
                      end
                    else
                      # No joined table, normal query
                      model_class.from(clean_query, model_table_name)
                    end

      # Apply the sorting logic
      return final_query.order(Arel.sql("LOWER(#{column_name}) #{sort_direction}")) if is_text_column

      # Case-insensitive sorting for text columns

      # Normal sorting for other column types
      final_query.order(Arel.sql("#{column_name} #{sort_direction}"))

    else
      # Normal queries without DISTINCT
      # reorder instead of order: previous ORDER BY clauses (e.g. from TicketSearchQuery)
      # are replaced, so that the user sorting always takes precedence
      return query.reorder(Arel.sql("LOWER(#{column_name}) #{sort_direction}")) if is_text_column

      query.reorder(Arel.sql("#{column_name} #{sort_direction}"))

    end
  end

  # For controllers that have their own default_sort_column
  def default_sort_column
    # Default implementation for controllers that do not have their own
    # Overridden by setup_sortable
    self.class.default_sort_column || 'created_at'
  end

  # Generic Turbo-Stream response for sorting
  def respond_to_sort(collection, frame_id, partial_path, locals = {})
    respond_to do |format|
      format.turbo_stream do
        if params[:sort].present?
          # Collect ALL active parameters that we need for the correct render response
          smart_folder_id = params[:smart_folder_id]
          active_smart_folder = nil

          # Try to load the SmartFolder if an ID is present
          if smart_folder_id.present?
            begin
              active_smart_folder = SmartFolder.find(smart_folder_id)
            rescue StandardError => e
              Rails.logger.error "respond_to_sort: Failed to load SmartFolder: #{e.message}"
            end
          end

          # Extend the locals with all important context information
          combined_locals = locals.merge(
            sortable_header: true,
            # Set all important context variables
            smart_folder_id: smart_folder_id,
            active_smart_folder: active_smart_folder || instance_variable_get(:@active_smart_folder),
            project_id: params[:project_id]
          )

          # Ensure that with this call we ALSO pass the collection to the partial
          combined_locals[collection.model.name.underscore.pluralize.to_sym] ||= collection

          render turbo_stream: [
            turbo_stream.replace(frame_id,
                                 partial: partial_path,
                                 locals: combined_locals)
          ]
        end
      end
      format.html { render :index }
    end
  end

  private

  def valid_columns
    self.class.sortable_columns_list || []
  end

  # Checks whether a sort column is valid
  def is_valid_sort_column?(column)
    # Ensure that sortable_columns_list is defined
    valid_columns = self.class.sortable_columns_list || []

    # If the column has a table prefix
    if column.include?('.')
      # Directly check whether the column is in the list
      is_valid = valid_columns.include?(column)

      # If not found, check whether it is in related_sortable_columns
      is_valid = self.class.related_sortable_columns.include?(column) if !is_valid && self.class.related_sortable_columns.present?
    else
      # If there is no table prefix, simply check directly
      is_valid = valid_columns.include?(column)

      # If not found, check with the table prefix
      is_valid = valid_columns.include?("#{model_table_name}.#{column}") if !is_valid && model_table_name
    end

    is_valid
  end
end
