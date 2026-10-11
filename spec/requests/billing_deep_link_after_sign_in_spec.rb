# frozen_string_literal: true

require 'rails_helper'

# What: a deep link to the billing hub survives the login redirect (N2 of
#       doc/billing_stammdaten_plan.md §18).
# Type: request spec, driven through the REAL Devise flow -- the stored location is
#       written by Devise's failure app on the rejected GET, not injected by hand. Faking
#       the session would test the regexp and skip the mechanism the bug lives in.
# Why:  ApplicationController#after_sign_in_path_for discards stored_location_for as soon
#       as the user has any organisation. That is right for ordinary pages, and wrong for
#       exactly the mails the Stripe phase will send ("payment reminder", "your billing
#       details are incomplete"): the customer clicks, logs in, and lands on the
#       organisation dashboard wondering what the mail was about.
RSpec.describe 'Deep link to the billing hub survives the login (N2)', type: :request do
  let(:account) { create(:account) }
  let(:organisation) { create(:organisation, account: account) }
  let(:user) { create(:user, password: 'password123') }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, active: true,
                          role: create(:admin_role, organisation: organisation))
    end
    account.update!(owner: user)
  end

  def sign_in_through_the_form
    post user_session_path, params: { user: { email: user.email, password: 'password123' } }
  end

  it 'sends the user to the billing page they originally asked for' do
    get organisation_billing_path(organisation)
    expect(response).to redirect_to(new_user_session_path)

    sign_in_through_the_form

    expect(response).to redirect_to(organisation_billing_path(organisation))
  end

  it 'also honours the edit page' do
    get edit_organisation_billing_path(organisation)

    sign_in_through_the_form

    expect(response).to redirect_to(edit_organisation_billing_path(organisation))
  end

  # K3: the ACCOUNT path is the canonical link now, so it is the one the reminder mails of
  # the Stripe phase will carry. Leaving it out of the pattern would mean exactly those
  # links stop surviving the login, while the org shortcut they no longer point at keeps
  # working -- the failure that looks fine in every manual test done from inside an org.
  it 'sends the user to the account billing page they originally asked for' do
    get billing_account_path(account)
    expect(response).to redirect_to(new_user_session_path)

    sign_in_through_the_form

    expect(response).to redirect_to(billing_account_path(account))
  end

  it 'also honours the account edit page' do
    get edit_billing_account_path(account)

    sign_in_through_the_form

    expect(response).to redirect_to(edit_billing_account_path(account))
  end

  it 'also honours the account summary' do
    get billing_accounts_path

    sign_in_through_the_form

    expect(response).to redirect_to(billing_accounts_path)
  end

  # The other half of the rule: everything else keeps the organisation redirect. Without
  # this, widening the pattern to "any stored location" would pass the two cases above and
  # quietly change where every other user lands after logging in.
  it 'still sends an ordinary deep link to the organisation dashboard' do
    get organisation_settings_path(organisation)

    sign_in_through_the_form

    expect(response).to redirect_to(organisation_root_path(organisation))
  end

  it 'sends a user without any deep link to their organisation as before' do
    sign_in_through_the_form

    expect(response).to redirect_to(organisation_root_path(organisation))
  end
end
