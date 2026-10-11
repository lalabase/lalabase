# frozen_string_literal: true

# Resolves a list's ordered columns and pins from its saved view or personal
# configuration. Both headers and rows consume these same ranked definitions.
module Lists
  class ResolveColumns
    def self.call(view_configuration:, smart_folder: nil)
      new(view_configuration: view_configuration, smart_folder: smart_folder).call
    end

    def initialize(view_configuration:, smart_folder: nil)
      @view_configuration = view_configuration
      @smart_folder = smart_folder
    end

    def call
      by_key = @view_configuration.available_columns.index_by { |column| column[:key] }
      rank = 0
      ViewConfiguration.normalize_columns(source_keys, @view_configuration.view_type).filter_map do |key|
        column = by_key[key]
        next unless column

        ranked = !column[:required]
        rank += 1 if ranked
        column.merge(rank: (rank if ranked),
                     min_width: ViewConfiguration.column_min_width(column),
                     pinned: pinned?(column))
      end
    end

    private

    def source_keys
      @smart_folder&.ordered_columns || @view_configuration.ordered_columns
    end

    # Pinned = its value stays readable under the title when its column no
    # longer fits. Number and title are pinned by definition and carry no
    # entry; for the rest the pins come from the SAME view the list comes from,
    # so a folder with its own columns brings its own pins.
    def pinned?(column)
      return true if column[:required]

      pinned_keys.include?(column[:key].to_s)
    end

    def pinned_keys
      @pinned_keys ||= @smart_folder&.pinned_column_keys || @view_configuration.pinned_column_keys
    end
  end
end
