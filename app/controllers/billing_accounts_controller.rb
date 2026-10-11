# frozen_string_literal: true

# The customer-facing billing area, on the level it actually talks about
# (K2 of doc/konto_ebene_plan.md). It lists the bundled organisations, sums the
# seats across them and computes an amount: every one of those is a statement
# about the ACCOUNT, not about one organisation below it.
#
# OUTSIDE the organisation scope, and that is the whole point. Its predecessor
# Organisations::BillingController sat under Organisations::BaseController, which
# demands an ACTIVE MEMBERSHIP in the organisation before any policy runs -- so an
# account owner who pays but does not work in the organisation could not reach
# their own billing data (N1 of doc/billing_stammdaten_plan.md §18). No tenant is
# loaded here, like the cockpit and the user preferences.
#
# NO ACTOR, deliberately, unchanged from the predecessor: a single `save` without
# side effects, transaction or job is a trivial write and stays in the controller
# per the seam rule. THAT CHANGES with the Stripe phase -- as soon as the change
# is pushed to Stripe it becomes a multi-step write with an external API call and
# belongs in Actors::SaveBillingDetails.
class BillingAccountsController < ApplicationController
  skip_before_action :load_tenant_from_session

  # Same contract as Organisations::BaseController: every action authorizes,
  # except index, whose visibility comes from Subscriptions::VisibleAccounts
  # rather than from a per-record check.
  after_action :verify_authorized, unless: -> { action_name == 'index' }

  before_action :set_account, only: %i[show edit update claim]

  def index
    @rows = Subscriptions::AccountSummaries.call(accounts: Subscriptions::VisibleAccounts.call(user: current_user))

    # The regular case today is one account, and a list of one is a click that
    # answers nothing. With several, the list is the answer.
    redirect_to billing_account_path(@rows.first.account) if @rows.size == 1
  end

  def show
    authorize @account, :show_overview?

    # Loading the discounts up front keeps the whole discount story at ONE
    # query: AmountPreview filters an already-loaded collection in memory
    # (documented there), and #active_discount reads the same rows instead of
    # asking the database a second time.
    @account.discounts.load
    @active_discount = active_discount
    @amount = amount_preview
    @organisations = @account.organisations.order(:name)
  end

  def edit
    authorize @account, :manage_billing?
  end

  def update
    authorize @account, :manage_billing?

    @account.assign_attributes(billing_params)
    # The :billing context is what enforces all-or-nothing (E3). It does NOT
    # enforce completeness: clearing every field is a legitimate save, and
    # "is this usable for an invoice" is #billing_complete?, asked elsewhere.
    if @account.save(context: :billing)
      redirect_to billing_account_path(@account), notice: t('controllers.billing_accounts.update.saved')
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def claim
    authorize @account, :claim?
    @account.claim!(current_user)
    redirect_to billing_account_path(@account), notice: t('controllers.billing_accounts.claim.claimed')
  rescue Account::AlreadyClaimedError
    # Races against the operator's assign_owner path in the admin backend.
    # Real enough to answer with a flash instead of a 500.
    redirect_to billing_account_path(@account), alert: t('controllers.billing_accounts.claim.already_claimed')
  end

  private

  # Account is not tenant-scoped, so a plain find is correct here -- the guard
  # against reading a stranger's account is the Pundit call in every action, not
  # a scope.
  def set_account
    @account = Account.find(params[:id])
  end

  # Seats are counted ONCE and handed to the preview (19.4/1). Both objects
  # would otherwise count them, and SeatCounter fans out one query per
  # organisation of the account -- exactly the duplicate its `seats:` keyword
  # exists to prevent.
  #
  # The interval comes from the account, not from the preview's monthly
  # default: an account the operator put on yearly billing must not be shown a
  # monthly figure as if it were its invoice amount.
  def amount_preview
    Subscriptions::AmountPreview.call(
      account: @account,
      seats: Subscriptions::SeatCounter.new(@account).call,
      billing_interval: @account.billing_interval
    )
  end

  # At most one discount can be active at a time (D3 of
  # doc/billing_preisliste_rabatt_plan.md, enforced by EffectiveDating); the
  # max_by only makes a violated invariant deterministic, and mirrors the same
  # tie-break inside AmountPreview so the shown discount can never disagree
  # with the deducted one.
  def active_discount
    @account.discounts.select { |discount| discount.effective_on?(Date.current) }
            .max_by(&:starts_on)
  end

  # One maintenance point for the field list (E5): the same constant feeds the
  # validations and the form. The system-set columns (vat_id_status,
  # vat_id_checked_*, business_confirmed_*) are absent from it on purpose --
  # otherwise a customer could put themselves on "VAT ID verified".
  def billing_params
    params.require(:account).permit(*Accounts::BillingRules::PERMITTED_FIELDS)
  end
end
