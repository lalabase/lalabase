# frozen_string_literal: true

module Subscriptions
  # Single owner module for the subscription vocabulary
  # (doc/billing_preisliste_rabatt_plan.md §4/D10). No plan key or interval
  # string is written literally anywhere else -- views, models and specs read
  # from here.
  #
  # BILLING_INTERVALS is a REGISTRY, not a list of allowed strings (D10): a bare
  # string would not carry `months`, and three places need it -- the monthly
  # equivalent on the pricing page (amount / months, never / 12), the period
  # length for proration (V5), and the saving calculation. A third interval
  # (quarterly, biennial) is therefore one entry here, not a code change.
  #
  # suggested_discount_percent has exactly ONE caller, and it is not in this
  # repository: Subscriptions::PriceListSeed in the operator engine
  # (gboyke/lalabase-operator, since S3.2), which derives the initial yearly
  # amounts from the monthly ones. The admin form does NOT use it -- it prefills all 14
  # amounts from the price level currently in force, which is the better answer
  # and made the planned "-20 %" button pointless. The truth stays the stored
  # amounts (V4); a hardcoded factor would be the second price source that this
  # whole plan removes.
  module Constants
    # Two prices for the same product (doc/billing_preisliste_rabatt_plan.md §13).
    # PLAN_CLOUD is every account without AI on the operator's own credentials:
    # no AI at all, or the organisation's own key. PLAN_CLOUD_AI is the price
    # with the operator's curated AI. The plan is BOOKED, not enforced: nothing
    # in the AI code reads it, an account on PLAN_CLOUD may still pick an AI
    # package, and the invoice settles it. Each plan has its own price levels;
    # PriceList, PriceLookup and PriceListGaps already work per plan.
    PLAN_CLOUD = 'cloud'
    PLAN_CLOUD_AI = 'cloud_ai'
    PLAN_KEYS = [PLAN_CLOUD, PLAN_CLOUD_AI].freeze

    # What a price level is denominated in unless it says otherwise. Named here
    # rather than repeated as a literal, so the day a second currency appears
    # there is one place to look instead of five.
    DEFAULT_CURRENCY = 'EUR'

    INTERVAL_MONTHLY = 'monthly'
    INTERVAL_YEARLY = 'yearly'

    BILLING_INTERVALS = {
      INTERVAL_MONTHLY => { months: 1, suggested_discount_percent: 0 },
      INTERVAL_YEARLY => { months: 12, suggested_discount_percent: 20 }
    }.freeze

    BILLING_INTERVAL_KEYS = BILLING_INTERVALS.keys.freeze

    # Coarse month length, used ONLY to turn a period in months into a ceiling
    # in days (Account#payment_terms_days). Deliberately generous rather than
    # exact: it guards against a typo'd payment term, it is not an accounting
    # figure, and nothing that computes money may use it.
    DAYS_PER_MONTH_APPROX = 30

    # Seat lifecycle (T16, doc/billing_agentur_konto_plan.md §17.2). Written once
    # here rather than as literals in the model, the recorder and every spec.
    #
    # TWO FAMILIES, and the split is load-bearing rather than descriptive.
    #
    # 1. MEMBERSHIP transitions, written by SeatEventRecording from Membership
    #    callbacks. They describe the SEAT, not the membership row: a membership
    #    that stays active but moves to a non-billable role emits DEACTIVATED,
    #    because Subscriptions::SeatCounter stops counting it. REMOVED is
    #    terminal, the membership row itself is gone.
    SEAT_EVENT_ACTIVATED = 'activated'
    SEAT_EVENT_DEACTIVATED = 'deactivated'
    SEAT_EVENT_REMOVED = 'removed'

    # 2. OPERATOR transitions (doc/abrechnungsmodell_plan.md A8). No membership
    #    changes when these are written, so no callback can produce them; they
    #    come from rake tasks. They exist because the stream has to record two
    #    things the membership callbacks structurally cannot see:
    #
    #    OPENING  -- the one-time starting state of an account. The stream began
    #                on a running system and therefore knows only who has changed
    #                since; without an explicit opening, a quiet account
    #                reconstructs to ZERO seats, and "not reconstructible yet" is
    #                indistinguishable from "nobody there". MIN(occurred_at)
    #                cannot stand in for it, because events written before the
    #                backfill would claim a reconstructability that does not
    #                exist.
    #    MOVED_OUT / MOVED_IN -- an organisation changing accounts. That writes
    #                organisations.account_id and touches no membership, so the
    #                timeline would otherwise break exactly where the account
    #                structure changes. Reusing REMOVED for the leaving half
    #                would make a move indistinguishable from a deletion and
    #                blind the audit trail.
    SEAT_EVENT_OPENING = 'opening'
    SEAT_EVENT_MOVED_IN = 'moved_in'
    SEAT_EVENT_MOVED_OUT = 'moved_out'

    SEAT_EVENTS_FROM_MEMBERSHIP = [SEAT_EVENT_ACTIVATED, SEAT_EVENT_DEACTIVATED,
                                   SEAT_EVENT_REMOVED].freeze
    SEAT_EVENTS_FROM_OPERATOR = [SEAT_EVENT_OPENING, SEAT_EVENT_MOVED_IN,
                                 SEAT_EVENT_MOVED_OUT].freeze

    SEAT_EVENTS = (SEAT_EVENTS_FROM_MEMBERSHIP + SEAT_EVENTS_FROM_OPERATOR).freeze

    # The two halves of ONE organisation changing accounts, named together
    # because M3 asks exactly this question: where does a month have to be cut
    # (A3)? `opening` is deliberately NOT in here -- it records a starting state,
    # it does not move anybody between accounts, and cutting a month at the
    # backfill moment would invent a boundary nobody agreed to.
    SEAT_EVENT_MOVES = [SEAT_EVENT_MOVED_IN, SEAT_EVENT_MOVED_OUT].freeze

    # Snapshot states (M1a/T18, doc/abrechnungsmodell_plan.md §4 step 1). Housed
    # here rather than on the model in one sentence: this module already owns
    # the seat vocabulary the snapshots are derived from, and M1b/M2 read both
    # sides together.
    #
    # Three states, and a MISSING row is deliberately a fourth. OK carries a
    # measured count. NOT_RECONSTRUCTIBLE says the boundary lies before
    # SeatEvent.reconstructible_from -- the count stays NULL, because a zero
    # there would be a lie rather than a measurement (§3). FAILED records that
    # the computation for this one account crashed (T18 point 3: held as a row,
    # not swallowed). The gap -- no row at all -- is what the M1b watcher hunts,
    # and it only stays detectable while no status doubles as "absent".
    SEAT_SNAPSHOT_STATUS_OK = 'ok'
    SEAT_SNAPSHOT_STATUS_NOT_RECONSTRUCTIBLE = 'not_reconstructible'
    SEAT_SNAPSHOT_STATUS_FAILED = 'failed'
    SEAT_SNAPSHOT_STATUSES = [SEAT_SNAPSHOT_STATUS_OK,
                              SEAT_SNAPSHOT_STATUS_NOT_RECONSTRUCTIBLE,
                              SEAT_SNAPSHOT_STATUS_FAILED].freeze

    # The statuses that count as an ANSWER: the boundary was asked and something
    # came back. "Cannot be known" IS an answer; a crashed attempt is not, so the
    # next run retries it. THE one owner of that split -- SeatSnapshot.answered
    # (the scope, for finding rows) and SeatSnapshot#answered? (the predicate,
    # for guarding a write) both read it here. Two hand-written copies of a
    # two-element list is exactly how a fourth status would end up on different
    # sides in the two places.
    SEAT_SNAPSHOT_ANSWERED_STATUSES = [SEAT_SNAPSHOT_STATUS_OK,
                                       SEAT_SNAPSHOT_STATUS_NOT_RECONSTRUCTIBLE].freeze

    # The stable log prefix of the whole snapshot chain (M1b). There is no
    # in-app alerting path in this project, so an ops-side watcher matches on
    # this string -- which makes it an interface, not a formatting choice. Every
    # producer reads it from here: the monthly job AND the manual rebuild, since
    # a hand-made correction of the billing basis is precisely what a watcher
    # should see.
    SEAT_SNAPSHOT_LOG_PREFIX = '[seat_snapshot]'

    # How many accounts a failure or gap listing names before it truncates. It
    # bounds the LOG LINE, never the check itself, and a truncating list always
    # says that it truncated -- a silent cap reads as "that was all of them".
    # Housed here because the job and the rebuild task both name failures and
    # must cap them the same way.
    SEAT_SNAPSHOT_MAX_NAMED = 10

    # An outcome-only value, deliberately NOT a fourth row status and therefore
    # NOT in SEAT_SNAPSHOT_STATUSES: it says what a RUN did, not what is known
    # about a boundary. A fill that computed a value and then found the row
    # already answered by a concurrent run reports this rather than `ok`,
    # because it wrote nothing and counting it as written would inflate the
    # summary line with work that never happened.
    SEAT_SNAPSHOT_OUTCOME_SKIPPED = 'skipped'

    # A6: the measurement month is a German calendar month, not a UTC month.
    # Boundaries are formed in this zone (SeatSnapshot.boundary_moment) while
    # storage and the app itself stay on UTC.
    BILLING_TIME_ZONE = 'Europe/Berlin'

    # What `counted` MUST be for a given type. A reconstruction reads `counted`
    # and never interprets the type, which only stays safe while the two agree --
    # hence a validation on SeatEvent rather than a sentence in a comment.
    #
    # Both directions matter, and they fail differently. A type that stopped the
    # seat but claims counted: true over-counts every later reconstruction, so the
    # invoice is too high. A type that started the seat but claims counted: false
    # under-counts, so it is too low. The first is the one that reaches a customer.
    #
    # OPENING is deliberately absent: it does not describe a transition, it
    # records whatever the state IS at backfill time, and that may be either.
    SEAT_EVENT_COUNTED_EXPECTATION = {
      SEAT_EVENT_ACTIVATED => true,
      SEAT_EVENT_MOVED_IN => true,
      SEAT_EVENT_DEACTIVATED => false,
      SEAT_EVENT_REMOVED => false,
      SEAT_EVENT_MOVED_OUT => false
    }.freeze

    # Months per billing period. Raises rather than defaulting to 1: a silent
    # fallback would turn an unknown interval into a wrong monthly equivalent.
    def self.months_for(billing_interval)
      definition = BILLING_INTERVALS.fetch(billing_interval) do
        raise ArgumentError, "unknown billing interval: #{billing_interval.inspect}"
      end
      definition.fetch(:months)
    end

    def self.suggested_discount_percent_for(billing_interval)
      BILLING_INTERVALS.fetch(billing_interval, {}).fetch(:suggested_discount_percent, 0)
    end
  end
end
