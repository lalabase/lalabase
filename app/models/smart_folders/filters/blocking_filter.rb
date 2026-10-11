# frozen_string_literal: true

module SmartFolders
  module Filters
    # "Hält andere auf" as a rule of a saved view (WaitingStateFilter).
    class BlockingFilter < WaitingStateFilter
      STATE = 'blocking'
    end
  end
end
