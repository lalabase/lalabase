# frozen_string_literal: true

# What a given seat count costs today, net
# (doc/billing_preisliste_rabatt_plan.md §5/D6): seats x rung minus the
# account's active discount. Joins the three pieces that already exist --
# SeatCounter, PriceLookup, AccountDiscount -- and is the only place before the
# Stripe phase where a wrong price or a wrong discount becomes visible.
#
# NOT A BILLING FORECAST. It answers "what does THIS seat count cost", not "what
# will be invoiced". Once subscriptions carry a period, the billed rung may
# legitimately be higher than the current seat count, because a seat reduction
# only takes effect at the end of the period (V5). Anything reusing this class
# for an invoice has to model that difference first.
#
# All amounts are NET (B2B, V1 of doc/billing_stammdaten_plan.md); VAT appears
# only with Stripe Tax. Hence subtotal/discount/total rather than net/gross.
module Subscriptions
  class AmountPreview
    Result = Struct.new(
      :seats, :tier, :subtotal_cents, :discount_percent, :discount_cents, :total_cents, :currency,
      :billing_start_decided,
      keyword_init: true
    ) do
      # Amounts are nil, never 0, when no price applies -- 0 would read as
      # "free" where the truth is "unknown".
      #
      # Two distinct reasons hide behind a nil tier, and conflating them made
      # the account page claim "no price level applies" for an account that
      # simply has nobody to bill -- contradicting the admin banner and the
      # rake check, which both said a price level was in force.
      def price_missing?
        tier.nil? && seats.to_i.positive?
      end

      def no_billable_seats?
        seats.to_i.zero?
      end

      # The THIRD case, and it belongs in this vocabulary rather than in a view
      # condition (R1 plan § 8): nobody has decided yet whether this account is
      # invoiced at all -- `billing_starts_on` is NULL, which E4 defines as "not
      # clarified", explicitly NOT as "free".
      #
      # It is a statement about the ACCOUNT, not about the arithmetic, so the
      # amount below it stays computed and correct. What changes is what a
      # customer-facing page may claim: showing a euro figure to somebody whose
      # billing has not been decided reads as an invoice nobody has promised. An
      # operator screen may keep showing it as "what this would cost".
      def billing_start_undecided?
        !billing_start_decided
      end

      def discounted?
        discount_percent.to_i.positive?
      end
    end

    def self.call(**kwargs)
      new(**kwargs).call
    end

    # seats: lets a caller that ALREADY counted pass the result in. The admin
    # account page did exactly that and paid for the count twice -- SeatCounter
    # fans out one query per organisation, so the duplicate scaled with the
    # account's size.
    # price_list: is the same kind of escape hatch as seats:, for a caller that
    # already resolved the level. Without it every iteration of a loop -- the
    # public pricing page, an account list -- would resolve it again and turn
    # into an N+1.
    # Distinguishes "no price_list argument" from "price_list: nil". A plain
    # truthiness check conflated the two, and the difference is exactly the N+1
    # the argument exists to prevent: a caller that already resolved the level
    # and got NIL (no price in force) would have every row look it up again.
    NO_PRICE_LIST_GIVEN = Object.new.freeze
    private_constant :NO_PRICE_LIST_GIVEN

    def initialize(account:, billing_interval: Constants::INTERVAL_MONTHLY,
                   plan_key: Constants::PLAN_CLOUD, on: Date.current,
                   seats: nil, price_list: NO_PRICE_LIST_GIVEN)
      @account = account
      @billing_interval = billing_interval
      @plan_key = plan_key
      @on = on
      @seats = seats
      @price_list_given = !price_list.equal?(NO_PRICE_LIST_GIVEN)
      @price_list = @price_list_given ? price_list : nil
    end

    def call
      # SeatCounter raises loudly on a broken organisation (D7 of the billing
      # plan) -- deliberately not rescued here: a silently skipped org would
      # surface as a wrong invoice months later.
      seats = @seats || SeatCounter.new(@account).call
      tier = resolve_tier(seats)
      return no_rung_result(seats) if tier.nil?

      build_result(seats, tier)
    end

    private

    # The result when no rung applies. EVERY field that describes the ACCOUNT
    # rather than the arithmetic has to be carried here too, and this path
    # dropped one twice -- found in two separate reviews of two different
    # callers:
    #
    #   * the discount, whose absence made a 100 % discounted account without a
    #     billable member read as "no discount" and fall out of the billing
    #     list's free section
    #   * the billing-start flag, whose default reported billing_start_undecided?
    #     as true for an account that IS billed -- the dangerous direction to get
    #     wrong by omission
    #
    # It is its own method for exactly that reason: two constructions of the
    # same value object invite the next field to be added to only one of them.
    def no_rung_result(seats)
      Result.new(seats: seats, tier: nil,
                 discount_percent: active_discount_percent,
                 billing_start_decided: billing_start_decided?)
    end

    def resolve_tier(seats)
      if @price_list_given
        # An explicitly passed nil means "resolved, and nothing applies".
        @price_list && PriceLookup.tier_in(@price_list, seats: seats, billing_interval: @billing_interval)
      else
        PriceLookup.tier_for(seats: seats, billing_interval: @billing_interval,
                             plan_key: @plan_key, on: @on)
      end
    end

    def build_result(seats, tier)
      subtotal_cents = tier.amount_cents_for(seats)
      percent = active_discount_percent
      discount_cents = discount_cents_for(subtotal_cents, percent)

      Result.new(
        seats: seats, tier: tier, subtotal_cents: subtotal_cents,
        discount_percent: percent, discount_cents: discount_cents,
        total_cents: subtotal_cents - discount_cents,
        # Carried from the price level rather than assumed: otherwise the
        # currency column is write-once dead data and every display path silently
        # renders euros.
        currency: tier.price_list.currency,
        billing_start_decided: billing_start_decided?
      )
    end

    # Reads the account rather than a date comparison: the question here is
    # whether the decision was MADE, not whether the period has started. A start
    # date in the future is decided, and a page that treats it as undecided
    # would tell a customer their billing is unclear when it is scheduled.
    def billing_start_decided?
      @account.billing_start_decided?
    end

    # Rounds half up on the cent, and rounds the DISCOUNT rather than the total:
    # integer division would truncate the discount downwards, i.e. always to the
    # customer's disadvantage.
    def discount_cents_for(subtotal_cents, percent)
      return 0 if percent.zero?

      (subtotal_cents * percent).fdiv(100).round
    end

    # At most one discount can be active (D3, enforced by EffectiveDating);
    # sorting only makes a violated invariant deterministic.
    #
    # Filters IN MEMORY when the association is already loaded -- the admin page
    # preloads discounts to render the history, and re-querying them here threw
    # that preload away.
    def active_discount_percent
      candidates =
        if @account.discounts.loaded?
          @account.discounts.select { |discount| discount.effective_on?(@on) }
        else
          @account.discounts.effective_on(@on).to_a
        end

      candidates.max_by(&:starts_on)&.percent_off.to_i
    end
  end
end
