# frozen_string_literal: true

# Searchable concern for controllers
# Enables simple text search across defined columns
module Searchable
  extend ActiveSupport::Concern

  included do
    class_attribute :searchable_model
    class_attribute :searchable_columns
  end

  class_methods do
    # Set up the search functionality for a model
    # @param model [Class] The model to search in
    # @param columns [Array<Symbol>] The columns to search in
    def setup_searchable(model, columns = [])
      self.searchable_model = model
      self.searchable_columns = columns
    end
  end

  # Applies the search parameters to the query
  # @param base_query [ActiveRecord::Relation] The base query
  # @return [ActiveRecord::Relation] The extended query with search conditions
  def apply_search(base_query)
    return base_query unless params[:search].present?

    search_term = params[:search].strip
    return base_query if search_term.blank?

    # Build ILIKE conditions for each column
    conditions = searchable_columns.map do |column|
      # For PostgreSQL we use ILIKE for case-insensitive search
      "LOWER(#{column_name_with_table(column)}) ILIKE LOWER(:search)"
    end

    # Combine all conditions with OR
    base_query.where(conditions.join(' OR '), search: "%#{search_term}%")
  end

  private

  # Adds the table name if the column does not include a table name
  # @param column [Symbol, String] The column name
  # @return [String] The full column name with the table name
  def column_name_with_table(column)
    column_name = column.to_s
    return column_name if column_name.include?('.')

    table_name = searchable_model.table_name
    "#{table_name}.#{column_name}"
  end
end
