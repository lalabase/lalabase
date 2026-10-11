# frozen_string_literal: true

module Meetings
  # Distinct job type for bound runs: an older worker must not silently execute
  # these as an instruction-free, transcript-only legacy generation. Deploy workers
  # before enabling new web instances; queued legacy TicketSuggestionJobs stay valid.
  class TicketSuggestionRunJob < TicketSuggestionJob
  end
end
