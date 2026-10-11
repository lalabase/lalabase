# frozen_string_literal: true

require 'rails_helper'

# What: the account LIST at /billing (K2 of doc/konto_ebene_plan.md) and the row partial
#       it shares with nothing else any more.
# Type: request spec, including an SQL counter via ActiveSupport::Notifications (same
#       shape as time_sessions_query_count_spec).
# Why:  Successor of spec/requests/organisations/select_account_block_spec.rb. The block
#       moved OFF the cockpit and into the account navigation, so the surface changed --
#       the two properties it guarded did not, and dropping them with the file would have
#       been the silent half of a UI change.
#
#   1. The cost shape. Asking AccountPolicy#show_overview? per row walks
#      account.organisations for every row, so the page would grow with the size of
#      somebody ELSE's account. That fan-out is invisible in development and in
#      production, because almost every account there bundles exactly ONE organisation.
#      The query-count expectation below is the only thing that would notice it coming
#      back.
#   2. What the row may claim about money. billing_starts_on is NULL on every account in
#      production, so the branch that HIDES the amount is the normal path, and a euro
#      figure in it reads as an invoice nobody agreed to.
RSpec.describe 'BillingAccounts list', type: :request do
  # Captures all SQL statements during the block (without SCHEMA/TRANSACTION/CACHE).
  def capture_sql(&)
    statements = []
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      next if %w[SCHEMA TRANSACTION CACHE].include?(payload[:name])

      statements << payload[:sql]
    end
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &)
    statements
  end

  def make_account_admin(user, org)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org, active: true,
                          role: create(:admin_role, organisation: org))
    end
  end

  # An account_admin, member of exactly TWO organisations in two different accounts: one
  # of constant size, and one that bundles `siblings` further organisations the user has
  # no membership in. The number of ROWS is therefore constant; only the SIZE of one
  # account varies.
  #
  # Two accounts and not one, because /billing forwards straight to the single account
  # when there is exactly one visible -- and the forward would never render the list this
  # guards.
  #
  # Deliberately an account_admin and NOT the owner: the owner check short-circuits
  # before the account's organisations are touched at all, so an owner would make the
  # scaling expectation below pass no matter how visibility is computed. The fan-out this
  # guards against lives entirely in the admin branch.
  #
  # ⚠️ THE SIBLINGS ARE CREATED FIRST, and that is load-bearing rather than incidental.
  # Account#eligible_owner? walks `organisations.any?` and STOPS at the first match. With
  # the user's own organisation created first it is also matched first, so a policy call
  # per row would cost exactly ONE query for a small account and ONE for a large one --
  # the difference would stay at the seat count, and the expectation below would hold
  # while guarding nothing. Measured: with the user's organisation first, reinstating the
  # per-row policy left the whole file green.
  #
  # The order is asserted rather than assumed (there is no ORDER BY behind
  # `organisations`), so an ordering change fails loudly instead of blinding the guard.
  #
  # What this ordering does NOT cover, and what the absolute ceiling below is for: a
  # version that collects candidates GLOBALLY (every account, then filter by policy) pays
  # the same surcharge on both users, so the difference stays correct while the page grows
  # with the number of accounts in the system.
  def admin_with_account_of(siblings:)
    user = create(:user)

    constant = create(:account, owner: create(:user), name: "Zweitkonto #{siblings}")
    make_account_admin(user, create(:organisation, account: constant))

    account = create(:account, owner: create(:user), name: "Konto mit #{siblings}")
    siblings.times { create(:organisation, account: account) }
    org = create(:organisation, account: account)
    make_account_admin(user, org)

    walk_order = account.organisations.map(&:id)
    expect(walk_order.index(org.id)).to eq(siblings),
                                        "fixture assumption broken: the user's organisation must be " \
                                        'walked LAST, otherwise the short-circuit hides the fan-out'
    [user, account]
  end

  # The way in. Until this entry existed the list lived on the cockpit, above the
  # organisations; the entry point is now a navigation item instead, and the block on the
  # cockpit is gone.
  #
  # It sits in the ACCOUNT navigation, which is the only one that renders without a
  # tenant (layouts/application.html.erb switches on @current_organisation). That is what
  # keeps N1 solved: an account owner who is a member of no organisation at all still has
  # a way in, and that person was the whole reason the area left the org scope.
  describe 'the way in' do
    it 'is a navigation entry on every org-free page, including for a user without any organisation' do
      owner = create(:user)
      create(:organisation, account: create(:account, owner: owner))
      expect(owner.memberships).to be_empty
      sign_in owner

      get select_organisation_path

      expect(response.body).to include(billing_accounts_path)
      expect(response.body).to include('Rechnungskonten')
      expect(response.body).not_to include('translation_missing')
    end

    # Both locales, read off the loaded backend rather than via I18n.exists?: with the
    # en->de fallback configured, exists? answers true for a key that exists only in
    # German, which is exactly the drift this catches.
    %i[de en].each do |locale|
      it "has the label in #{locale}" do
        stored = I18n.backend.send(:translations)[locale]&.dig(:navigation, :billing_accounts)

        expect(stored).to be_present
      end
    end
  end

  # The money half. billing_starts_on is NULL on every account in production, so this is
  # the NORMAL path here, not an edge case.
  describe 'what a row says about money' do
    def owner_of_two_accounts
      owner = create(:user)
      account = create(:account, owner: owner, name: 'Konto mit Preis')
      org = create(:organisation, account: account)
      make_account_admin(owner, org)
      # Second visible account, so the list renders instead of forwarding.
      create(:organisation, account: create(:account, owner: owner, name: 'Zweitkonto'))
      create(:price_list, :with_v4_monthly_ladder)
      [owner, account]
    end

    it 'names the state instead of an amount while billing has not been decided' do
      owner, account = owner_of_two_accounts
      expect(account.billing_starts_on).to be_nil
      sign_in owner

      get billing_accounts_path

      expect(response.body).to include(I18n.t('views.billing_accounts.row.state.undecided'))
      # The seat count stays: how many people are counted is a fact about the account,
      # not a claim about billing.
      expect(response.body).to include(I18n.t('views.billing_accounts.row.seats', count: 1))
      expect(response.body).not_to include('translation_missing')
    end

    it 'shows the amount once somebody has decided that the account is billed' do
      owner, = owner_of_two_accounts
      # BOTH accounts decided, so the "undecided" needle below cannot be satisfied by the
      # second row instead of refuted by the first. The second has no members and lands on
      # `no_seats`, which is a different sentence.
      Account.where(owner_id: owner.id).find_each { |a| a.update!(billing_starts_on: Date.current) }
      sign_in owner

      get billing_accounts_path

      # The FORMATTED figure, not the digits '29': asset digest hashes put that substring
      # on the page dozens of times over, so a bare needle is true by construction. See
      # spec/support/price_formatting.rb for the measurement.
      expect(response.body).to include(formatted_price(2900))
      expect(response.body).not_to include(I18n.t('views.billing_accounts.row.state.undecided'))
    end
  end

  describe 'cost shape' do
    it 'grows by exactly one query per additional organisation in the account' do
      siblings = 5
      small_user, small_account = admin_with_account_of(siblings: 0)
      large_user, large_account = admin_with_account_of(siblings: siblings)

      sign_in small_user
      small = capture_sql { get billing_accounts_path }
      expect(response.body).to include(billing_account_path(small_account))
      sign_out small_user

      sign_in large_user
      large = capture_sql { get billing_accounts_path }
      expect(response.body).to include(billing_account_path(large_account))

      expect(large.size - small.size).to eq(siblings)

      # Second, independent signal, deliberately LOOSE. The difference alone cannot see a
      # regression that charges both users the same surcharge -- collecting candidates
      # globally and filtering by policy does exactly that, and the measured cost went
      # from 21 queries to 28 with the difference untouched.
      #
      # A ceiling rather than an exact number, because an exact one would break on every
      # unrelated change to this page and get raised without being read. If this trips,
      # the question is not "which number now" but "what did the page start doing", and
      # the answer belongs in this comment before the number moves.
      expect(small.size).to be <= 30
    end
  end
end
