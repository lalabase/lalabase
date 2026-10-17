# frozen_string_literal: true

# Entry point: Meetings::ListState.extract
# Whitelists the state shared by list URLs, forms and redirects.
module Meetings
  # The list's address contract, shared by forms, links, and frame responses.
  #
  # Beside it the lane's list context (doc/meetings_uebersicht_vereinheitlichen_plan.md,
  # PR 3): the detail of a meeting is project-nested, and opened from "Alle
  # Meetings" its forms and links carry list_context=organisation, so that a save
  # redraws that list and not the project's. One allowed value, compared and
  # never interpolated; any other value is the project list. It chooses which
  # list is rendered, never what anyone may read. Not part of KEYS: it is no
  # state of a list, and no list address carries it.
  module ListState
    SCALAR_KEYS = %w[search search_mode participant smart_folder_id page items limit viewport].freeze
    NESTED_KEYS = %w[filter filter_op filter_drop sort].freeze
    KEYS = (SCALAR_KEYS + NESTED_KEYS).freeze

    CONTEXT_KEY = 'list_context'
    ORGANISATION_CONTEXT = 'organisation'

    def self.extract(params)
      params.permit(*SCALAR_KEYS, filter: {}, filter_op: {}, filter_drop: [], sort: %i[column direction]).to_h.compact_blank
    end

    def self.organisation?(params)
      params[CONTEXT_KEY] == ORGANISATION_CONTEXT
    end

    # The context as query parameters: what a form or a link of the lane adds.
    def self.context_query(organisation:)
      organisation ? { CONTEXT_KEY => ORGANISATION_CONTEXT } : {}
    end
  end
end
