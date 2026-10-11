# frozen_string_literal: true

# Why is the time list empty? Names the filters whose removal brings rows back.
#
# Entry point: call
#
# S3 of doc/zeiten_filterzeile_und_stand_plan.md (finding F5). The list carries
# up to seven filters at once and TWO of them are defaults nobody chose (this
# month, billed hidden), so one generic sentence left the reader guessing which
# of seven to touch.
#
# The method is drop-one: leave each filter out on its own and ask whether
# anything comes back. Every filter is an AND, so leaving one out can only ever
# WIDEN the result. A filter named here is therefore a filter whose removal
# really does bring rows back, and the page may promise exactly that. It also
# means the page can promise it while removing MORE than the named filter (the
# project pill takes the subject with it, see the view): more removed is more
# rows, never fewer.
#
# Cost: nothing at all while the list has rows, and one EXISTS per active filter
# when it does not.
module TimeSessions
  class EmptyReason
    # One removable unit per filter: the key the page speaks in, and the
    # TimeSessionFilterService attributes that unit owns. Read from the one
    # owner, TimeSessions::ListFilters, in its order, which is the order the
    # filter row is read in and the order the pills are offered in.
    #
    # The smart folder is deliberately absent. It is not one of these filters but
    # the base query itself (the controller resolves it before any of this). A
    # folder that matches nothing leaves `active` empty, and the view answers
    # that with the reset link to the neutral list, which drops the folder too.
    REMOVABLE = TimeSessions::ListFilters::ALL.to_h { |filter| [filter.key, filter.attributes] }.freeze

    # `culprits` are the filters to offer for removal, `active` every filter that
    # currently narrows anything. The difference is what the view says: culprits
    # means "take one away and the list fills up", active-but-no-culprits means
    # "no single one of them explains this", and neither means the emptiness does
    # not come from these filters at all.
    Reason = Data.define(:culprits, :active)

    def self.call(base_query:, filters:)
      new(base_query: base_query, filters: filters).call
    end

    def initialize(base_query:, filters:)
      @base_query = base_query
      @filters = filters
    end

    def call
      # The premise, checked rather than assumed: there is nothing to explain
      # while the filtered query HAS rows. The caller asks because the page it
      # rendered came out empty, and a page can be empty over a query that is
      # not -- ?page=5 of a three-page list is exactly that. Answering "the
      # period is to blame" there would name a filter whose removal changes
      # nothing about the empty page in front of the reader.
      return Reason.new(culprits: [], active: []) if full_query.exists?

      narrowing = REMOVABLE.keys.select { |key| narrows?(key) }
      Reason.new(culprits: narrowing.select { |key| rows_without?(key) }, active: narrowing)
    end

    private

    # Does this unit narrow anything RIGHT NOW? Asked of the query rather than of
    # the parameters, so the answer cannot drift from what the filter service
    # actually does: three status pills are no filter at all (the service says
    # so), an unparseable date is no filter (the service drops it), and a blank
    # value is no filter. Comparing the built SQL costs no round trip.
    #
    # An answer that is wrong in the safe direction costs little: a unit called
    # narrowing that narrows nothing builds the same (empty) query in the probe
    # below, so it never becomes a culprit -- at worst it stands in `active` and
    # the view says "no single filter explains this" instead of the generic
    # sentence. The opposite cannot happen: two queries that differ cannot build
    # the same SQL, so a filter that really narrows is never overlooked.
    def narrows?(key)
      query_without(key).to_sql != full_query.to_sql
    end

    def rows_without?(key)
      query_without(key).exists?
    end

    def full_query
      @full_query ||= build(@filters)
    end

    def query_without(key)
      @query_without ||= {}
      @query_without[key] ||= build(@filters.except(*REMOVABLE.fetch(key)))
    end

    # Every attribute of TimeSessionFilterService defaults to nil, so leaving a
    # key out IS switching that filter off.
    def build(attributes)
      TimeSessionFilterService.new(base_query: @base_query, **attributes).call
    end
  end
end
