# frozen_string_literal: true

require 'rails_helper'

# What: the customer-facing billing area, on the account level (B2/B3 of
#       doc/billing_stammdaten_plan.md §11, moved up one level by K2 of
#       doc/konto_ebene_plan.md).
# Type: request spec.
# Why:  Three of the properties here fail SILENTLY and expensively.
#
#   0. The reason the area moved at all: an account OWNER needs no membership anywhere.
#      The predecessor sat below Organisations::BaseController, which demands an active
#      membership before any policy runs, so a customer who pays but does not work in the
#      organisation could not reach their own billing data (N1). Nothing looked broken --
#      the only owner in production happens to be a member of every one of their orgs.
#   1. E6 splits reading into two levels: seats and the bundled organisations are open to
#      every active account_admin, the invoice master data is the owner's alone. A leak
#      would hand the org admin of one bundled customer org the address and tax data of a
#      different legal entity, and nothing in the UI would look wrong.
#   2. The verification and confirmation columns are set by the system. If mass assignment
#      ever reaches them, a customer can put themselves on "VAT ID verified" and the field
#      that is supposed to be evidence becomes a self-report.
#
# Production context worth knowing while reading this file: every account there bundles
# exactly ONE organisation today, so the agency cases below are not observable in
# operation. These specs are the only thing standing between them and the first real
# bundled account.
RSpec.describe 'BillingAccounts', type: :request do
  let(:account) { create(:account) }
  let(:organisation) { create(:organisation, account: account) }
  let(:owner) { create(:user) }

  # Complete, valid master data -- the starting point for the change cases, so a rejected
  # save can only come from the thing under test and not from an unrelated missing field.
  let(:complete_attributes) do
    { billing_name: 'Muster GmbH', billing_street: 'Musterweg 1',
      billing_postal_code: '10115', billing_city: 'Berlin',
      billing_country: 'DE', billing_email: 'rechnung@muster.de' }
  end

  def make_account_admin(user, org)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org, active: true,
                          role: create(:admin_role, organisation: org))
    end
  end

  def sign_in_owner
    make_account_admin(owner, organisation)
    account.update!(owner: owner)
    sign_in owner
  end

  describe 'GET show' do
    # [CRITICAL] N1, and the single example that proves the new route earns its existence.
    # The owner has NO membership in the organisation their account bundles -- the agency
    # case: someone pays for a customer org they do not work in. On the old org-scoped
    # route this request never reached a policy at all.
    it 'lets an owner without any membership reach their own billing data' do
      organisation
      account.update!(owner: owner, **complete_attributes)
      expect(owner.memberships).to be_empty

      sign_in owner
      get billing_account_path(account)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Muster GmbH')
      expect(response.body).to include(organisation.name)
    end

    # [CRITICAL] The other half: no relation to the account, no access. Asserted on the
    # billing data rather than on the status alone, so a future change that renders a
    # partial page instead of redirecting cannot pass this quietly.
    it 'refuses a user with no relation to the account' do
      account.update!(owner: create(:user), **complete_attributes)
      organisation
      stranger_org = create(:organisation)
      stranger = create(:user)
      make_account_admin(stranger, stranger_org)
      sign_in stranger

      get billing_account_path(account)

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))
      expect(response.body).not_to include('Muster GmbH')
    end

    it 'shows the owner the seats, the bundled organisations and the billing details' do
      sibling = create(:organisation, account: account, name: 'Schwester GmbH')
      account.update!(**complete_attributes)
      sign_in_owner

      get billing_account_path(account)

      expect(response).to have_http_status(:ok)
      # ALL bundled organisations, not just the current one: that list is the reason the
      # account level exists, and showing only the current org would make the page look
      # correct while hiding what is actually being billed.
      expect(response.body).to include(sibling.name)
      expect(response.body).to include(organisation.name)
      expect(response.body).to include('Muster GmbH')
    end

    # [CRITICAL] E6, the read half. The account_admin legitimately sees the overview; the
    # invoice master data of a possibly foreign legal entity must not travel with it.
    it 'shows a non-owner account_admin the overview but NOT the billing details' do
      account.update!(**complete_attributes)
      account.update!(owner: create(:user))
      admin = create(:user)
      make_account_admin(admin, organisation)
      sign_in admin

      get billing_account_path(account)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(organisation.name)
      expect(response.body).not_to include('Muster GmbH')
      expect(response.body).not_to include('rechnung@muster.de')
      expect(response.body).not_to include(edit_billing_account_path(account))
    end

    it 'refuses a member of the organisation who is neither owner nor account_admin' do
      account.update!(owner: create(:user))
      member = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: member, organisation: organisation, active: true,
                            role: create(:role, organisation: organisation))
      end
      sign_in member

      get billing_account_path(account)

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))
    end

    describe 'the claim banner' do
      it 'appears for an eligible admin of an owner-less account' do
        admin = create(:user)
        make_account_admin(admin, organisation)
        sign_in admin

        get billing_account_path(account)

        expect(response.body).to include(I18n.t('views.billing_accounts.show.claim_button'))
      end

      it 'stays away once the account has an owner' do
        sign_in_owner

        get billing_account_path(account)

        expect(response.body).not_to include(I18n.t('views.billing_accounts.show.claim_button'))
      end
    end

    describe 'the amount preview (19.4/1 + 19.4/2)' do
      # An amount is only shown once somebody has decided that this account is
      # invoiced at all -- see the not-billed example below for why.
      before { account.update!(billing_starts_on: Date.current) }

      it 'shows the price of the current seat count minus the active discount' do
        create(:price_list, :with_v4_monthly_ladder)
        # 25 %, NOT 50 %. At half off, the deducted amount and the remaining total are the
        # SAME number (1450 of 2900), so a page rendering the subtotal where the total
        # belongs shows the expected figures anyway. Measured: with 50 % this example
        # stayed green while the view printed an UNDISCOUNTED total, which is precisely
        # the mistake its name promises to catch. A quarter makes the three amounts three
        # distinct numbers.
        create(:account_discount, account: account, percent_off: 25)
        sign_in_owner

        get billing_account_path(account)

        # One billable seat (the owner) -> the 29 EUR rung, minus a quarter.
        #
        # All three needles FORMATTED. `include('29')` used to stand here and could not
        # fail: asset digest hashes put those digits on every page about seventy times
        # over, including on a page that shows no amount at all.
        expect(response.body).to include(formatted_price(2900))
        expect(response.body).to include(formatted_price(725))
        expect(response.body).to include(formatted_price(2175))
        expect(response.body).to include(I18n.t('views.billing_accounts.show.preview_disclaimer'))
      end

      # A missing price rung is our gap, not the customer's. Wording it as an error would
      # produce a support request nobody on the customer side can act on.
      it 'says the price is still being sorted out when no rung applies' do
        sign_in_owner

        get billing_account_path(account)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(
          I18n.t('views.billing_accounts.show.price_pending', count: 1)
        )
      end

      # [CRITICAL] R1 plan § 8: an account whose billing has not been decided
      # (billing_starts_on IS NULL, which E4 defines as "not clarified", NOT as
      # "free") must not be shown a euro figure. Under R1 the invoice is written
      # by hand outside the application, so an amount here reads as a promise
      # nobody made. The two examples above had to be given a start date for
      # exactly this reason -- before this branch existed they asserted the
      # amount for an account that was never agreed to be billed.
      context 'when nobody has decided whether this account is billed' do
        before { account.update!(billing_starts_on: nil) }

        it 'says so instead of showing a figure' do
          create(:price_list, :with_v4_monthly_ladder)
          sign_in_owner

          get billing_account_path(account)

          expect(response).to have_http_status(:ok)
          expect(response.body).to include(I18n.t('views.billing_accounts.show.not_billed'))
        end

        it 'shows no amount at all, not even a zero' do
          create(:price_list, :with_v4_monthly_ladder)
          sign_in_owner

          get billing_account_path(account)

          # The 29 EUR rung would apply to the owner's seat; nothing of it may reach the page.
          #
          # Asserted on the TABLE, not on a formatted figure. format_price_cents
          # renders whole euros WITHOUT decimals ("29 €"), so needles like '29,00'
          # or '0,00' never occur anywhere in this app -- an assertion against them
          # holds just as well on a page that shows the full amount, i.e. it cannot
          # fail and guards nothing. The row labels are the formatting-independent
          # statement "no amount table was rendered".
          expect(response.body).not_to include(I18n.t('views.billing_accounts.show.total_row'))
          expect(response.body).not_to include(I18n.t('views.billing_accounts.show.seats_row', count: 1))
          # The disclaimer belongs to the amount. Left standing it would talk about
          # "die Vorschau" and "die naechste Rechnung" one line under the notice that
          # says there is neither.
          expect(response.body).not_to include(
            I18n.t('views.billing_accounts.show.preview_disclaimer')
          )
        end

        # A start date in the FUTURE is a decision, not an open question. Telling
        # that customer their billing is unclear would be the opposite error.
        it 'still shows the amount when the start date is merely still ahead' do
          create(:price_list, :with_v4_monthly_ladder)
          account.update!(billing_starts_on: 1.month.from_now.to_date)
          sign_in_owner

          get billing_account_path(account)

          expect(response.body).not_to include(I18n.t('views.billing_accounts.show.not_billed'))
          # The amount table itself, not the digits '29': asset digest hashes put
          # that substring on the page 70 times over, so it is true by construction.
          expect(response.body).to include(I18n.t('views.billing_accounts.show.total_row'))
        end
      end
    end

    # B4 widened the gate on this page from "address or e-mail" to
    # #billing_details_present?, which asks about every field the customer can fill in.
    # That opened a state the partial had never rendered in: a block whose address and
    # e-mail rows are BOTH empty. Those rows always render, so they needed an empty state,
    # and the empty state needed a key -- which is where it went wrong the first time.
    describe 'the billing details block' do
      # Regression. `views.billing_accounts.details.not_set` was used by the partial
      # while existing in NEITHER locale, so this page shipped
      # <span class="translation_missing">Not Set</span> to a German customer.
      #
      # Nothing caught it: raise_on_missing_translations is commented out in
      # config/environments/test.rb, so a missing key renders instead of raising, and
      # i18n-tasks does not see the key either -- the reference is real, the definition is
      # what is absent.
      #
      # The German string is pinned as a LITERAL, not built from the same t() call the view
      # makes. Built from t(), the expectation would move with the defect: delete the key
      # again and both sides degrade together, and the example stays green.
      it 'labels the empty address and e-mail rows in German, not as a missing translation' do
        account.update!(billing_reference: 'PO-4711')
        sign_in_owner

        get billing_account_path(account)

        expect(response.body).to include('PO-4711')
        # Twice: the address row and the e-mail row are separate call sites.
        expect(response.body.scan('Nicht hinterlegt').size).to eq(2)
        # The mechanism, not just the string: this is what stays true if the key is
        # renamed, moved, or dropped from one of the two locale files.
        expect(response.body).not_to include('translation_missing')
      end

      # The other side of the widened gate. An untouched account has nothing to show, and
      # a block of nothing but "Nicht hinterlegt" rows would be worse than no block.
      it 'stays away entirely when the customer has filled in nothing' do
        sign_in_owner

        get billing_account_path(account)

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(
          I18n.t('views.billing_accounts.details.address_label')
        )
      end
    end
  end

  describe 'GET index' do
    it 'forwards straight to the account when the user can see exactly one' do
      organisation
      account.update!(owner: owner)
      sign_in owner

      get billing_accounts_path

      expect(response).to redirect_to(billing_account_path(account))
    end

    it 'lists the accounts when there are several, and only those the user may see' do
      organisation
      account.update!(owner: owner, name: 'Erstes Konto')
      second = create(:account, owner: owner, name: 'Zweites Konto')
      create(:organisation, account: second)
      # A third account the owner has nothing to do with. Named distinctly so the
      # assertion cannot pass on a substring of the other two.
      foreign = create(:account, owner: create(:user), name: 'Fremdes Konto')
      create(:organisation, account: foreign)
      sign_in owner

      get billing_accounts_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Erstes Konto')
      expect(response.body).to include('Zweites Konto')
      expect(response.body).not_to include('Fremdes Konto')
    end

    # Same rule as on the cockpit: an account left behind by a move is still owned,
    # still authorized and still reachable by URL, it simply stops advertising
    # itself. Asserted on BOTH surfaces because they are two call sites of one
    # filter, and a fix applied to only one of them is exactly the drift the
    # shared row partial exists to prevent.
    it 'leaves an account without organisations out of the list' do
      organisation
      account.update!(owner: owner, name: 'Volles Konto')
      emptied = create(:account, owner: owner, name: 'Leergelaufenes Konto')
      sign_in owner

      get billing_accounts_path

      # One visible account left, so index forwards rather than listing.
      expect(response).to redirect_to(billing_account_path(account))
      follow_redirect!
      expect(response.body).not_to include('Leergelaufenes Konto')
      # Still reachable for whoever holds the link, and still authorized.
      get billing_account_path(emptied)
      expect(response).to have_http_status(:ok)
    end

    # A member of organisations who owns nothing and administers nothing. Renders the
    # empty state rather than forwarding somewhere or failing.
    it 'says so when the user is responsible for no account at all' do
      account.update!(owner: create(:user))
      member = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: member, organisation: organisation, active: true,
                            role: create(:role, organisation: organisation))
      end
      sign_in member

      get billing_accounts_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('views.billing_accounts.index.empty'))
      # The mechanism, not just the string: every key on this page has to exist in the
      # locale the page renders in. raise_on_missing_translations is off in the test
      # environment, so nothing else would notice a missing one.
      expect(response.body).not_to include('translation_missing')
    end
  end

  describe 'GET edit' do
    it 'renders the form for the owner' do
      sign_in_owner

      get edit_billing_account_path(account)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('views.billing_accounts.edit.save'))
    end

    # §9: the Stimulus controller must read the country rules from
    # Accounts::BillingRules and never restate them in JavaScript. Checking the rendered
    # data attribute is what makes that verifiable from outside -- a JS-side copy would
    # still make the form behave correctly today and drift the first time a country
    # changes sides, with nothing to notice it.
    it 'hands the country rules to the form instead of duplicating them in JavaScript' do
      sign_in_owner

      get edit_billing_account_path(account)

      required = Accounts::BillingRules::VAT_ID_REQUIRED_COUNTRIES
      expect(response.body).to include(CGI.escapeHTML(required.to_json))
      expect(required).to include('FR')
      expect(required).not_to include('DE')
    end

    it 'refuses a non-owner account_admin' do
      account.update!(owner: create(:user))
      admin = create(:user)
      make_account_admin(admin, organisation)
      sign_in admin

      get edit_billing_account_path(account)

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))
    end
  end

  describe 'PATCH update' do
    it 'saves complete data for the owner' do
      sign_in_owner

      patch billing_account_path(account), params: { account: complete_attributes }

      expect(response).to redirect_to(billing_account_path(account))
      expect(account.reload.billing_city).to eq('Berlin')
      expect(account).to be_billing_complete
    end

    it 'rejects half-filled data and re-renders the form' do
      sign_in_owner

      patch billing_account_path(account),
            params: { account: complete_attributes.merge(billing_city: '') }

      expect(response).to have_http_status(:unprocessable_content)
      expect(account.reload.billing_city).to be_blank
    end

    # E3: clearing everything is a legitimate save, not a validation error. Losing this
    # would leave a customer unable to remove data they once entered.
    it 'accepts clearing every field' do
      account.update!(**complete_attributes)
      sign_in_owner

      patch billing_account_path(account),
            params: { account: complete_attributes.transform_values { '' } }

      expect(response).to redirect_to(billing_account_path(account))
      expect(account.reload.billing_name).to be_blank
    end

    # [CRITICAL] E6, the write half. A denied request must not be a partially applied one:
    # the field is put into the body by hand, exactly as an attacker would.
    it 'does not let a non-owner account_admin change the data, even with a hand-made body' do
      account.update!(**complete_attributes)
      account.update!(owner: create(:user))
      admin = create(:user)
      make_account_admin(admin, organisation)
      sign_in admin

      patch billing_account_path(account),
            params: { account: { billing_city: 'Hamburg', billing_email: 'angreifer@example.com' } }

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))
      expect(account.reload).to have_attributes(billing_city: 'Berlin',
                                                billing_email: 'rechnung@muster.de')
    end

    # [CRITICAL] The system-set columns. vat_id_status in particular is evidence: if a
    # customer can set it, "VAT ID verified" stops meaning that anyone verified anything.
    # The confirmed-by column is the same class of claim about a person.
    it 'ignores the verification and confirmation columns submitted with the form' do
      sign_in_owner
      stranger = create(:user)

      patch billing_account_path(account), params: {
        account: complete_attributes.merge(
          vat_id_status: 'valid',
          vat_id_checked_at: Time.current,
          vat_id_checked_name: 'Selbst bestätigt',
          business_confirmed_at: Time.current,
          business_confirmed_by_id: stranger.id,
          business_confirmation_version: 'v1'
        )
      }

      expect(response).to redirect_to(billing_account_path(account))
      expect(account.reload).to have_attributes(
        vat_id_status: 'unchecked', vat_id_checked_at: nil, vat_id_checked_name: nil,
        business_confirmed_at: nil, business_confirmed_by_id: nil,
        business_confirmation_version: nil
      )
      # The legitimate part of the same request still went through, so this proves the
      # filter and not merely that the whole save failed.
      expect(account.billing_city).to eq('Berlin')
    end

    # The operator-only billing state (W3): a customer writing their own billing_starts_on
    # or payment_terms_days would be writing their own invoice.
    it 'ignores the operator-only billing state columns' do
      account.update!(payment_terms_days: 14, billing_starts_on: nil)
      sign_in_owner

      patch billing_account_path(account), params: {
        account: complete_attributes.merge(payment_terms_days: 365,
                                           billing_starts_on: 1.year.from_now.to_date,
                                           billing_interval: 'yearly')
      }

      expect(account.reload).to have_attributes(payment_terms_days: 14, billing_starts_on: nil,
                                                billing_interval: 'monthly')
    end
  end

  describe 'POST claim' do
    it 'makes an eligible admin the owner of an owner-less account' do
      admin = create(:user)
      make_account_admin(admin, organisation)
      sign_in admin

      post claim_billing_account_path(account)

      expect(response).to redirect_to(billing_account_path(account))
      expect(account.reload.owner).to eq(admin)
    end

    # Races the operator's assign_owner path in the admin backend. Real enough to answer
    # with a flash rather than a 500.
    it 'answers with a flash when someone else claimed it first' do
      admin = create(:user)
      make_account_admin(admin, organisation)
      sign_in admin
      allow_any_instance_of(Account).to receive(:claim!).and_raise(Account::AlreadyClaimedError)

      post claim_billing_account_path(account)

      expect(response).to redirect_to(billing_account_path(account))
      expect(flash[:alert]).to eq(I18n.t('controllers.billing_accounts.claim.already_claimed'))
    end

    it 'refuses a claim on an account that already has an owner' do
      account.update!(owner: create(:user))
      admin = create(:user)
      make_account_admin(admin, organisation)
      sign_in admin

      post claim_billing_account_path(account)

      expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))
      expect(account.reload.owner).not_to eq(admin)
    end
  end
end
