# frozen_string_literal: true

module SmartFolders
  module Filters
    # "Wartet auf offenes Ticket" as a rule of a saved view (WaitingStateFilter).
    class WaitingFilter < WaitingStateFilter
      STATE = 'waiting'
    end
  end
end
