# frozen_string_literal: true

require 'rails_helper'

# D4 (Plan doc/billing_agentur_konto_plan.md, [CRITICAL] plan-mandated
# regression test, §4.2): Account-Owner-Sein / account_admin-Sein in ONE
# organisation of an Account grants NO automatic data access to ANOTHER
# organisation of the SAME Account. Bundling organisations under one Account
# is a billing concept (D2) only -- org-level access control is untouched by
# it and still runs entirely through Membership, exactly as before Account
# existed.
#
# What:     an account_admin of org A, and separately an Account owner with
#           no membership anywhere, must both be refused when trying to
#           reach an organisation-scoped page for org B of the same Account.
# Why:      this invariant was flagged CRITICAL in the original /plan-eng-review
#           (D4) specifically so a future change that couples Account to org
#           access would be caught here -- nothing in this Account/Guest-Ceiling
#           work touches access control, so this is a regression guard, not a
#           new behaviour.
# Contract: the target org is always resolved via current_user.organisations
# (through :memberships, s. ApplicationController#load_tenant_from_session and
# Organisations::BaseController#set_organisation) -- having no Membership row
# for org B means org B is simply not in that collection, regardless of any
# Account relationship. Which exact failure mode surfaces depends on whether
# the user has ANY other organisation (load_tenant_from_session's fallback
# redirects to the org picker) or none at all (falls through to
# set_organisation's raw ActiveRecord::RecordNotFound, rendered as 404) --
# either way, org B's data is never reached.
RSpec.describe 'Account bundling grants no cross-org access (D4)', type: :request do
  let(:account) { create(:account) }
  let(:org_a) { create(:organisation, account: account) }
  let(:org_b) { create(:organisation, account: account) }

  it "does not grant org A's account_admin any access to org B" do
    admin = create(:user)
    ActsAsTenant.with_tenant(org_a) do
      admin_role = create(:admin_role, organisation: org_a)
      create(:membership, user: admin, organisation: org_a, role: admin_role, active: true)
    end
    sign_in admin

    get organisation_root_path(organisation_id: org_b.id)

    # admin DOES have another organisation (org A), so
    # load_tenant_from_session's fallback redirects to the org picker rather
    # than raising -- either way, org B is never resolved as the tenant.
    expect(response).to redirect_to(select_organisation_path)
  end

  it 'does not grant the Account owner (with no membership anywhere) any org access' do
    org_a # ensure the account has at least one organisation
    owner = create(:user)
    account.update!(owner: owner)
    sign_in owner

    get organisation_root_path(organisation_id: org_a.id)

    expect(response).to have_http_status(:not_found)
  end

  it "org A's account_admin keeps full access to org A itself (sanity check)" do
    admin = create(:user)
    ActsAsTenant.with_tenant(org_a) do
      admin_role = create(:admin_role, organisation: org_a)
      create(:membership, user: admin, organisation: org_a, role: admin_role, active: true)
    end
    sign_in admin

    get organisation_root_path(organisation_id: org_a.id)

    expect(response).to have_http_status(:ok)
  end
end
