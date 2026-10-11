# frozen_string_literal: true

# One STORABLE date bound out of a string somebody typed, or nil.
#
# Entry point: call
#
# Two questions live here, not one. `Date.strptime` answers "is this a calendar
# date" and says yes to "999999999-01-01" and to "-9999-01-01": %Y takes any
# number of digits and a leading sign. PostgreSQL stores neither, so the next
# query dies with PG::DatetimeFieldOverflow -- a 500 instead of an answer, from a
# parameter anybody can type. The four-digit FORM check is what closes that gap,
# and it has to run BEFORE the parse, because after it the year is already a
# perfectly valid Ruby Date.
#
# ONE owner since S3c T3. The rule stood written by hand in the chat tool
# (Lalabase::Tools::SummarizeTimeSessions) and was copied into the assistant's
# report panel (Assistant::Panels::TimeReport) -- where the form half was lost on
# the way over and the panel answered a crafted address with a 500. Both take a
# date bound out of an address a person can reach, so both go through here.
module TimeSessions
  class DateBound
    # Four digits, no sign. That is the window PostgreSQL can hold, and it is the
    # only part of the rule a calendar parser will not check for you.
    FORMAT = /\A\d{4}-\d{2}-\d{2}\z/

    # => 'YYYY-MM-DD' or nil. Never raises: nil means "no bound", which is what
    # both callers already do with a value they cannot use.
    def self.call(value:)
      raw = value.to_s.strip
      return nil unless raw.match?(FORMAT)

      Date.strptime(raw, '%Y-%m-%d').to_s
    rescue Date::Error
      nil
    end

    # For callers that refuse the whole request on a bad argument rather than
    # dropping the filter.
    def self.valid?(value:)
      !call(value: value).nil?
    end
  end
end
