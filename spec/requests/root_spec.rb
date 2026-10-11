# frozen_string_literal: true

require 'rails_helper'

# The bare domain used to redirect to /de, the German marketing page. On
# lalabase.com nginx never lets a request reach the core there, so that only
# ever showed on a SELF-HOSTED instance -- which greeted its visitors with our
# marketing, our pricing and our company in the footer, on their own server
# (website split, W6).
RSpec.describe 'The bare domain', type: :request do
  it 'sends a visitor who is not signed in to the sign-in form' do
    get '/'

    expect(response).to redirect_to(new_user_session_path)
  end

  context 'with a signed-in user' do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user) }

    it 'sends them to their organisation' do
      ActsAsTenant.with_tenant(organisation) { create(:membership, user: user, organisation: organisation) }
      sign_in user

      get '/'

      expect(response).to redirect_to(organisation_root_path(organisation))
    end

    # Rare but reachable: an account whose membership was removed. It used to
    # land on /de through after_sign_in_path_for's root_path fallback, which is
    # remapped to the marketing page.
    it 'sends one without an organisation to the cockpit, not to a marketing page' do
      sign_in user

      get '/'

      expect(response).to redirect_to(select_organisation_path)
    end
  end
end
