# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::DashboardController, type: :controller do
  before do
    # Set up routes for this controller
    routes.draw do
      root 'static#index'
      namespace :admin do
        root 'dashboard#index'
        get 'dashboard', to: 'dashboard#index'
        get 'log_in', to: 'sessions#new'
        post 'log_in', to: 'sessions#create'
        get 'log_out', to: 'sessions#destroy'
      end
    end
  end

  # Test authentication without hitting controller actions
  describe 'authentication' do
    before do
      @request.env['devise.mapping'] = Devise.mappings[:user]

      # Mock the admin authentication behavior to prevent authentication issues
      allow(controller).to receive(:current_user).and_return(nil)
      allow(controller).to receive(:logged_in?).and_call_original
    end

    it 'requires authentication' do
      get :index
      expect(response).to be_redirect
    end
  end

  # Test basic controller action
  describe 'GET #index' do
    # A Beuser, not a User. The admin area authenticates against its own backend account
    # (session[:beuser_id], deliberately separate from Devise), and
    # Admin::Authentication#require_login gates on current_user.admin? — a method only Beuser
    # has. Handed an app User, the filter raised NoMethodError instead of exercising the gate.
    let(:user) { create(:beuser) }

    before do
      # Set up the mapping for Devise
      @request.env['devise.mapping'] = Devise.mappings[:user]

      # Mock authentication
      allow(controller).to receive(:current_user).and_return(user)
      allow(controller).to receive(:user_signed_in?).and_return(true)
      allow(controller).to receive(:authenticate_user!).and_return(true)
    end

    it 'renders the index template' do
      get :index
      expect(response).to be_successful
      expect(response).to render_template(:index)
    end
  end
end
