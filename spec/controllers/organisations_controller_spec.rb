# frozen_string_literal: true

require 'rails_helper'

RSpec.describe OrganisationsController, type: :controller do
  describe 'authentication' do
    before do
      @request.env['devise.mapping'] = Devise.mappings[:user]
      allow(controller).to receive(:authenticate_user!) do
        controller.redirect_to new_user_session_path
      end
      allow(controller).to receive(:user_signed_in?).and_return(false)
      allow(controller).to receive(:current_user).and_return(nil)
    end

    it 'requires authentication for select' do
      get :select
      expect(response).to redirect_to(new_user_session_path)
    end

    it 'requires authentication for set' do
      post :set, params: { organisation_id: '123' }
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
