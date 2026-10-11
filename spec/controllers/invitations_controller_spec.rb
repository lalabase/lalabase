# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Organisations::InvitationsController, type: :controller do
  before do
    # Set up routes for this controller
    routes.draw do
      root 'static#index'
      scope path: '/org/:organisation_id', module: :organisations, as: :organisation do
        resources :invitations, only: %i[new create show edit update destroy]
      end
    end
  end

  # Test authentication without hitting controller actions
  describe 'authentication' do
    before do
      @request.env['devise.mapping'] = Devise.mappings[:user]

      # Mock the BaseController behavior to prevent it from trying to access current_user.organisations
      allow(controller).to receive(:set_organisation).and_return(true)
      allow(controller).to receive(:set_current_membership).and_return(true)
      allow(controller).to receive(:current_user).and_return(nil)
      allow(controller).to receive(:user_signed_in?).and_return(false)
      allow(controller).to receive(:authenticate_user!).and_call_original
    end

    it 'requires authentication' do
      get :new, params: { organisation_id: '123' }
      expect(response).to be_redirect
    end
  end

  # Test controller private methods with minimal auth mocking
  describe 'private methods' do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user) }

    before do
      # Set up the mapping for Devise
      @request.env['devise.mapping'] = Devise.mappings[:user]

      # Set tenant
      ActsAsTenant.current_tenant = organisation

      # Mock authentication
      allow(controller).to receive(:current_user).and_return(user)
      allow(controller).to receive(:user_signed_in?).and_return(true)
      allow(controller).to receive(:current_organisation).and_return(organisation)
      allow(controller).to receive(:authenticate_user!).and_return(true)
      allow(controller).to receive(:set_organisation).and_return(true)
      allow(controller).to receive(:set_current_membership).and_return(true)

      # Set organisation instance variables
      controller.instance_variable_set(:@organisation, organisation)
      controller.instance_variable_set(:@current_organisation, organisation)
    end

    after do
      ActsAsTenant.current_tenant = nil
    end

    describe '#invitation_params' do
      it 'permits the correct parameters' do
        # Mock params with invitation attributes
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           invitation: {
                                                             email: 'test@example.com'
                                                           }
                                                         ))

        # Call the method
        result = controller.send(:invitation_params)

        # Verify permitted parameters
        expect(result.to_h).to include(
          'email' => 'test@example.com'
        )
      end
    end
  end
end
