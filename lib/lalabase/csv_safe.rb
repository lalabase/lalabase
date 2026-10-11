# frozen_string_literal: true

module Lalabase
  # Neutralises spreadsheet formulas in CSV cells built from user text.
  #
  # A spreadsheet opens a cell that starts with = + - @ (or a tab or carriage
  # return in front of one) as a formula, so an organisation name like
  # "=HYPERLINK(...)" becomes a live link in the admin's spreadsheet. A leading
  # apostrophe makes the cell plain text (OWASP "CSV Injection").
  #
  # Only strings are touched: numbers and timestamps the export writes itself
  # stay as they are, a negative Integer included.
  module CsvSafe
    FORMULA_TRIGGERS = ['=', '+', '-', '@', "\t", "\r"].freeze

    module_function

    def row(values)
      values.map { |value| cell(value) }
    end

    def cell(value)
      return value unless value.is_a?(String) && value.start_with?(*FORMULA_TRIGGERS)

      "'#{value}"
    end
  end
end
