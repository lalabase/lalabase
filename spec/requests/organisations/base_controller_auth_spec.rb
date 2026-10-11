# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Organisations::BaseController authentication', type: :request do
  describe 'when the session is absent (e.g. Devise timeout)' do
    it 'redirects to the login page instead of raising a 500' do
      get organisation_memberships_path(organisation_id: SecureRandom.uuid)

      expect(response).to have_http_status(:found)
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
