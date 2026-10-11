# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Organisations::MembershipsController, type: :controller do
  before do
    # Set up routes for this controller
    routes.draw do
      root 'static#index'
      scope path: '/org/:organisation_id', module: :organisations, as: :organisation do
        resources :memberships, only: %i[index edit update destroy]
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
      get :index, params: { organisation_id: '123' }
      expect(response).to be_redirect
    end
  end

  # Test controller private methods with minimal auth mocking
  describe 'private methods' do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user) }
    let(:role) do
      ActsAsTenant.with_tenant(organisation) do
        create(:role, organisation: organisation)
      end
    end
    let(:membership) do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, role: role)
      end
    end

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

    describe '#membership_params' do
      it 'permits the correct parameters' do
        # Mock params with membership attributes
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           membership: {
                                                             role_id: role.id,
                                                             active: true
                                                           }
                                                         ))

        # Call the method
        result = controller.send(:membership_params)

        # Verify permitted parameters
        expect(result.to_h).to include(
          'role_id' => role.id,
          'active' => true
        )
      end
    end
  end
end
