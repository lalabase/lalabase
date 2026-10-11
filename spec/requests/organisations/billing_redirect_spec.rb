# frozen_string_literal: true

require 'rails_helper'

# What: the old org-scoped billing route, now a pure forwarder (K3 of
#       doc/konto_ebene_plan.md).
# Type: request spec.
# Why:  The route is live, bookmarked and the target of the "Rechnung" settings tab.
#       Removing it outright would break all three; leaving it as a second
#       implementation would give the billing area two places to disagree with itself.
#       Forwarding is what keeps both from happening, and these examples are what says
#       so out loud.
RSpec.describe 'Organisations::Billing forwards to the account', type: :request do
  let(:account) { create(:account) }
  let(:organisation) { create(:organisation, account: account) }
  let(:admin) { create(:user) }

  def make_account_admin(user, org)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org, active: true,
                          role: create(:admin_role, organisation: org))
    end
  end

  before do
    make_account_admin(admin, organisation)
    sign_in admin
  end

  it 'forwards the show page to the account path' do
    get organisation_billing_path(organisation)

    expect(response).to redirect_to(billing_account_path(account))
  end

  it 'forwards the edit page to the account edit path' do
    get edit_organisation_billing_path(organisation)

    expect(response).to redirect_to(edit_billing_account_path(account))
  end

  # The settings tab is the reason this route survives at all, so the link it renders is
  # pinned to the route that still exists. Reading it from the helper's own table rather
  # than restating the path keeps this from being a second copy of the tab definition.
  it 'is what the "Rechnung" settings tab still points at' do
    tab = NavigationHelper::SETTINGS_TABS.find { |entry| entry[:key] == :billing }

    expect(tab[:path_helper]).to eq(:organisation_billing_path)
    expect(organisation_billing_path(organisation)).to be_present
  end

  # E9b: organisations.account_id is still nullable, so there is an organisation shape
  # with nothing to forward TO. Answering with a flash is what keeps that from being a
  # 500 on a page whose whole job is to be reachable. Moved here with the route it
  # describes; the account controller cannot reach this state, it is found by id.
  it 'answers with a flash instead of raising when the organisation has no account' do
    orphan_org = create(:organisation)
    orphan_org.update_columns(account_id: nil)
    orphan_admin = create(:user)
    make_account_admin(orphan_admin, orphan_org)
    sign_in orphan_admin

    get organisation_billing_path(orphan_org)

    expect(response).to redirect_to(organisation_root_path(orphan_org))
    expect(flash[:alert]).to eq(I18n.t('controllers.billing_accounts.missing_account'))
  end

  # The forward deliberately does NOT authorize -- the target does, in full. This pins
  # that decision: a member who may not see the billing area still gets forwarded, and is
  # then denied by the account page. Without the example, adding a policy check here
  # would look like a harmless improvement rather than a second gate to keep in sync.
  it 'forwards a member who may not see the area, and lets the target deny them' do
    member = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: member, organisation: organisation, active: true,
                          role: create(:role, organisation: organisation))
    end
    sign_in member

    get organisation_billing_path(organisation)
    expect(response).to redirect_to(billing_account_path(account))

    follow_redirect!
    expect(response).to have_http_status(:redirect)
    expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))
  end

  # The write routes are GONE (K3): the forms post to the account paths now, and a write
  # route whose only job would be to forward a body it cannot forward is a trap. Pinned
  # because "the route still exists but does nothing" is the failure this prevents.
  # Asked of the routing table rather than by firing a request: whether an unrouted
  # request raises or renders a 404 page depends on show_exceptions, which is an
  # environment setting and not the property under test.
  it 'no longer offers the update and claim routes below the organisation' do
    routes = Rails.application.routes
    path = "/org/#{organisation.id}/billing"

    expect { routes.recognize_path(path, method: :patch) }
      .to raise_error(ActionController::RoutingError)
    expect { routes.recognize_path("#{path}/claim", method: :post) }
      .to raise_error(ActionController::RoutingError)

    # The counterpart, so the two expectations above cannot pass because the whole route
    # is gone rather than only its write half.
    expect(routes.recognize_path(path, method: :get))
      .to include(controller: 'organisations/billing', action: 'show')
  end
end
