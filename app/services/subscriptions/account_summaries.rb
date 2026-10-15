# frozen_string_literal: true

# One row per account for the overview surfaces (K1/K4 of
# doc/konto_ebene_plan.md): the cockpit block above the organisations and the
# account index. Turns a list of accounts into what those pages render, so the
# two of them cannot disagree about seats or amount.
#
# The price levels of all plans are resolved ONCE for the whole list and each
# row gets the one of its account's plan via `price_list:`. Without that each
# row would resolve the ladder again, which is the N+1 that argument exists to
# prevent. `tier_in` then filters the already loaded tiers in memory, so the
# ladders cost the same few queries no matter how many rows there are.
#
# Seats are the one cost that DOES scale, and it scales with the size of the
# account rather than with the number of rows: SeatCounter walks each
# organisation under its own tenant (D5, deliberately not a cross-tenant
# query in a money path). K4's query-count expectation is written against
# exactly that shape -- one query per bundled organisation and nothing else.
module Subscriptions
  class AccountSummaries
    # The one state that renders an AMOUNT rather than a label. Named once here
    # and used twice below, so "which state prints a figure" is a fact in the
    # code instead of a hand-maintained exception in a guard -- the second such
    # state would otherwise have to be remembered in two unrelated places.
    AMOUNT_STATE = :billed

    # Every value Row#state can return. Compared against the parsed source of
    # #state by spec/locales/billing_account_row_states_spec.rb.
    ROW_STATES = %i[undecided no_seats price_pending billed].freeze

    # The states the row renders as TEXT, i.e. the ones that need a label in both
    # locales. Derived, not restated: the guard checks these keys exist, and
    # nobody has to keep two lists in step.
    #
    # Why the guard exists at all: the `t("...#{row.state}")` in the row partial
    # builds its key dynamically, so a new state without a label renders
    # "translation missing" into the customer page without failing anything
    # (raise_on_missing_translations is off in the test environment, and
    # i18n-tasks does not see a reference without a definition).
    LABELLED_ROW_STATES = (ROW_STATES - [AMOUNT_STATE]).freeze

    Row = Struct.new(:account, :organisations, :amount, keyword_init: true) do
      delegate :seats, to: :amount

      # What the customer-facing row may claim about money.
      #
      # `undecided` comes FIRST because it is the more fundamental statement:
      # with billing_starts_on NULL nobody has decided whether this account is
      # invoiced at all (E4), and an amount there reads as an invoice no one
      # promised. Today that is the normal state, not an edge case -- it holds
      # for every account on production.
      #
      # Same order as the billing hub itself, so the row and the page it links to
      # cannot say different things about the same account.
      def state
        return :undecided if amount.billing_start_undecided?
        return :no_seats if amount.no_billable_seats?
        return :price_pending if amount.price_missing?

        :billed
      end

      # The seat count stays visible in EVERY state: how many people are counted
      # is a fact about the account, not a claim about billing.
      def amount_shown?
        state == AMOUNT_STATE
      end
    end

    def self.call(**kwargs)
      new(**kwargs).call
    end

    def initialize(accounts:)
      @accounts = accounts
    end

    def call
      price_lists = PriceLookup.current_by_plan

      displayable(@accounts).map do |account|
        Row.new(
          account: account,
          organisations: account.organisations.sort_by(&:name),
          amount: amount_for(account, price_lists[account.plan_key])
        )
      end
    end

    private

    # An account without organisations says nothing to a customer: no seats, no
    # amount, nothing to act on. It exists because a move left it behind (K7 of
    # doc/konto_ebene_plan.md keeps it, deleting would take discounts and
    # applications with it), so it is an artefact of an OPERATOR action that the
    # customer never asked for.
    #
    # Worse than useless, measured on production right after the first real move:
    # the leftover account carries the organisation's old name, so it renders as
    # a row that looks exactly like a duplicate of the organisation now bundled
    # one row below. It even nags for missing invoice details, for an account
    # that invoices nothing.
    #
    # The predicate lives on Account (#without_organisations?) because the admin
    # list asks the SAME question and answers it the opposite way: it labels the
    # account instead of hiding it. Two surfaces, one fact -- restating it here
    # is how the two would eventually disagree about which accounts are meant.
    #
    # Filtered HERE and not in Subscriptions::VisibleAccounts on purpose. That
    # object answers "may this user see it", and its agreement with
    # AccountPolicy#show_overview? is pinned. This is a different question:
    # "is there anything to show". The account stays reachable by URL, stays
    # authorized, and stays fully listed in the admin backend
    # (Admin::AccountsController#index has no such filter) -- it just stops
    # advertising itself. Give it an organisation again and it comes back.
    #
    # `organisations` arrives preloaded from VisibleAccounts, so this costs no
    # query.
    def displayable(accounts)
      accounts.reject(&:without_organisations?)
    end

    # Sorted in Ruby rather than via .order: the organisations arrive preloaded
    # from VisibleAccounts, and an ordered re-query would throw that preload away
    # and reintroduce one query per row.
    #
    # The interval comes from the account, not from AmountPreview's monthly
    # default -- an account the operator put on yearly billing must not be shown
    # a monthly figure as if it were its invoice amount.
    def amount_for(account, price_list)
      AmountPreview.call(
        account: account,
        seats: SeatCounter.new(account).call,
        billing_interval: account.billing_interval,
        price_list: price_list
      )
    end
  end
end
