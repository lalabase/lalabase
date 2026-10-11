# frozen_string_literal: true

# Entry point: Meetings::ListState.extract
# Whitelists the state shared by list URLs, forms and redirects.
module Meetings
  # The list's address contract, shared by forms, links, and frame responses.
  module ListState
    SCALAR_KEYS = %w[search search_mode participant smart_folder_id page items limit viewport].freeze
    NESTED_KEYS = %w[filter filter_op filter_drop sort].freeze
    KEYS = (SCALAR_KEYS + NESTED_KEYS).freeze

    def self.extract(params)
      params.permit(*SCALAR_KEYS, filter: {}, filter_op: {}, filter_drop: [], sort: %i[column direction]).to_h.compact_blank
    end
  end
end
