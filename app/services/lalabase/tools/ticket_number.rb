# frozen_string_literal: true

module Lalabase
  module Tools
    # Parses the ticket number users see in the app ("#187") out of a tool
    # argument. Shared by every tool that accepts a number as an address
    # (GetTicket, SummarizeTimeSessions), so the rule is written once.
    #
    # Tolerant on the way in ("187", 187, "#187", stray blanks), strict on what
    # counts as a number. The strict half is load-bearing: "abc".to_i is silently
    # 0, so without it a typo would send a real lookup for ticket number 0 and
    # come back with "no ticket found" — a wrong answer wearing database
    # authority, instead of a refused argument.
    module TicketNumber
      FORMAT = /\A#?\s*(\d+)\z/

      # @return [Integer, nil] the positive whole number, or nil for anything
      #   that is not one — decided BEFORE any query.
      def self.parse(raw)
        match = raw.to_s.strip.match(FORMAT)
        return nil if match.nil?

        number = match[1].to_i
        number.positive? ? number : nil
      end
    end
  end
end
