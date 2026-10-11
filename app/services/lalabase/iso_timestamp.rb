# frozen_string_literal: true

# One STORABLE point in time out of an ISO 8601 string somebody typed, or nil.
#
# Entry point: parse
#
# The sibling of TimeSessions::DateBound for timestamps, for the same reason:
# a parser alone says yes to a five-digit year, which PostgreSQL cannot hold,
# so the four-digit FORM is checked BEFORE the parse. Accepts a date (midnight
# in the app zone), a date with time, seconds, a fraction, "Z" or an offset.
# Two callers (the inbox `since` bound, the time booking's `occurred_on`), which
# is one more than a rule may be written by hand.
#
# The offset is spelled out (hours 00-23, minutes 00-59) because the parser
# behind it is lenient the wrong way round: Date._iso8601 answers `offset: nil`
# for "+99:99" or "+24:00" and Time.zone.iso8601 then reads the whole string as
# zone-less, so a malformed offset would silently land at the wrong instant
# instead of being refused.
module Lalabase
  module IsoTimestamp
    OFFSET = /(?:Z|[+-](?:[01]\d|2[0-3]):?[0-5]\d)/
    FORMAT = /\A\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2}(\.\d+)?)?#{OFFSET}?)?\z/

    # => ActiveSupport::TimeWithZone or nil. Never raises.
    def self.parse(value)
      raw = value.to_s.strip
      return nil unless raw.match?(FORMAT)

      # The calendar check the time parser skips: Time.new rolls "2026-02-30"
      # over to March 2nd, Date.strptime refuses it.
      Date.strptime(raw[0, 10], '%Y-%m-%d')
      Time.zone.iso8601(raw)
    rescue ArgumentError
      nil
    end
  end
end
