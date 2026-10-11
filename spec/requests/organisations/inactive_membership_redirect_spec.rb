# frozen_string_literal: true

require 'rails_helper'

# Regression guard for the organisation-entry redirect LOOP.
#
# What:  entering an organisation whose membership is not active (active: false, or
#        the legacy active: NULL state from before the column was backfilled) must
#        NOT drop the user into an automatic redirect cycle.
# Art:   request spec — exercises the full before_action + redirect chain.
# Why:   Organisations::BaseController#set_current_membership used to redirect such
#        users to root_path (static#index). For a single-org user, static#index
#        immediately sends them back to the organisation root -> briefings ->
#        set_current_membership -> root_path -> ... an infinite loop (the browser
#        hangs). The fix redirects to the terminal organisation picker instead.
#        root_path is the looping target; select_organisation_path only renders and
#        never auto-redirects, so it terminates the chain.
# Contract: a user without an ACTIVE membership for an org receives a single,
#        terminal redirect to the organisation picker — never to root_path.
RSpec.describe 'Org entry with an inactive membership', type: :request do
  let(:organisation) { create(:organisation) }
  let(:role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  context 'when the membership exists but is deactivated' do
    before do
      create(:membership, user: user, organisation: organisation, role: role, active: false)
      sign_in user
    end

    # The core regression: the redirect target moved off root_path (which loops for
    # single-org users) to the terminal picker.
    it 'redirects to the terminal org picker, not to the looping root_path' do
      get organisation_root_path(organisation_id: organisation.id)

      expect(response).to redirect_to(select_organisation_path)
      expect(response).not_to redirect_to(root_path)
    end

    # Proves the chain actually terminates: following the redirect lands on a
    # rendered page (200), not another 302 back into the org (the old loop).
    it 'lands on a rendered page after following the redirect (no further bounce)' do
      get organisation_root_path(organisation_id: organisation.id)
      follow_redirect!

      expect(response).to have_http_status(:ok)
    end
  end
end
