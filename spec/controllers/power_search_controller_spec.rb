# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Organisations::PowerSearchController, type: :controller do
  before do
    Rails.application.routes.draw do
      namespace :organisations do
        resources :power_search, only: [:index] do
          collection do
            post :execute
          end
        end
      end
    end
  end

  after do
    Rails.application.reload_routes!
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

    it 'requires authentication for index' do
      get :index, params: { organisation_id: 'test' }
      expect(response).to be_redirect
    end

    it 'requires authentication for execute' do
      post :execute, params: { organisation_id: 'test', power_search_query: 'test' }
      expect(response).to be_redirect
    end
  end

  # Test basic controller actions with auth mocking
  describe 'controller actions' do
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

      # Mock BaseController methods
      allow(controller).to receive(:set_organisation).and_return(organisation)
      allow(controller).to receive(:set_current_membership).and_return(true)
    end

    after do
      ActsAsTenant.current_tenant = nil
    end

    describe 'GET #index' do
      it 'renders the index template' do
        get :index, params: { organisation_id: organisation.id }
        expect(response).to be_successful
        expect(response).to render_template(:index)
      end
    end

    describe 'POST #execute' do
      it 'calls PowerSearchService and assigns results' do
        # Mock the PowerSearchService
        search_service = instance_double(PowerSearchService)
        search_results = [%w[type result]]

        allow(PowerSearchService).to receive(:new).with('test', organisation, nil, user).and_return(search_service)
        allow(search_service).to receive(:execute).and_return(search_results)
        # #execute also asks the service whether semantic search degraded, so the view can tell
        # the user the results are keyword-only. Unstubbed, the verifying double rejected it.
        allow(search_service).to receive(:semantic_degraded?).and_return(false)

        # Execute the action
        post :execute, params: { organisation_id: organisation.id, power_search_query: 'test' }

        # Verify results are assigned
        expect(assigns(:results_with_type)).to eq(search_results)
      end
    end
  end
end
