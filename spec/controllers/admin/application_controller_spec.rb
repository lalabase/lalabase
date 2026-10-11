# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::ApplicationController, type: :controller do
  # Anonymous controller that inherits from Admin::ApplicationController,
  # giving us access to all its behavior (Authentication, flash.keep, etc.)
  controller(Admin::ApplicationController) do
    # Required by Admin::Authentication concern for unauthenticated redirects
    def admin_log_in_path
      '/admin/log_in'
    end

    def index
      render plain: 'ok'
    end

    def action_with_redirect
      redirect_to '/admin/dashboard'
    end

    def action_with_flash_and_redirect
      flash[:notice] = 'First notice'
      redirect_to '/admin/target'
    end
  end

  before do
    routes.draw do
      namespace :admin do
        get 'application/index', to: 'application#index'
        get 'application/action_with_redirect', to: 'application#action_with_redirect'
        get 'application/action_with_flash_and_redirect', to: 'application#action_with_flash_and_redirect'
        get 'dashboard', to: 'dashboard#index'
        get 'log_in', to: 'sessions#new'
      end
    end
  end

  let(:beuser) { create(:beuser, email: 'admin@example.com', active: true) }

  # ==========================================================================
  # Authentication integration
  # ==========================================================================
  describe 'authentication via Admin::Authentication concern' do
    context 'when not logged in' do
      it 'redirects to admin login path' do
        get :index
        expect(response).to redirect_to('/admin/log_in')
      end

      it 'does not render the action' do
        get :index
        expect(response.body).not_to include('ok')
      end
    end

    context 'when logged in' do
      before { session[:beuser_id] = beuser.id }

      it 'allows the request' do
        get :index
        expect(response).to have_http_status(:ok)
        expect(response.body).to eq('ok')
      end
    end

    context 'when session references deleted beuser' do
      before do
        session[:beuser_id] = beuser.id
        # The instance refuses to lose its last active admin.
        create(:beuser, email: 'second-admin@example.com', active: true)
        beuser.destroy!
      end

      it 'redirects to login' do
        get :index
        expect(response).to redirect_to('/admin/log_in')
      end
    end

    context 'when session user_id is empty string' do
      before { session[:beuser_id] = '' }

      it 'redirects to login' do
        get :index
        expect(response).to redirect_to('/admin/log_in')
      end
    end

    context 'when session user_id is nil' do
      before { session[:beuser_id] = nil }

      it 'redirects to login' do
        get :index
        expect(response).to redirect_to('/admin/log_in')
      end
    end
  end

  # ==========================================================================
  # redirect_to override (flash.keep behavior)
  # ==========================================================================
  describe '#redirect_to override' do
    before { session[:beuser_id] = beuser.id }

    it 'preserves flash messages across redirects' do
      get :action_with_flash_and_redirect

      expect(response).to redirect_to('/admin/target')
      expect(flash[:notice]).to eq('First notice')
    end

    it 'calls super to perform the actual redirect' do
      get :action_with_redirect

      expect(response).to have_http_status(:redirect)
      expect(response).to redirect_to('/admin/dashboard')
    end

    it 'returns 302 status' do
      get :action_with_redirect

      expect(response.status).to eq(302)
    end
  end

  # ==========================================================================
  # Layout configuration
  # ==========================================================================
  describe 'layout' do
    it 'configures admin backend layout' do
      expect(described_class._layout).to eq('admin/backend_application')
    end
  end

  # ==========================================================================
  # CSRF protection
  # ==========================================================================
  describe 'CSRF protection' do
    it 'has forgery protection enabled' do
      expect(described_class.forgery_protection_strategy).not_to be_nil
    end
  end

  # ==========================================================================
  # Dead code removal verification
  # ==========================================================================
  describe 'removed dead code' do
    it 'does not define application_layout' do
      expect(described_class.instance_methods(false)).not_to include(:application_layout)
    end

    it 'does not define is_this_staging?' do
      expect(described_class.instance_methods(false)).not_to include(:is_this_staging?)
    end

    it 'does not register is_this_staging? as helper method' do
      expect(described_class._helper_methods).not_to include(:is_this_staging?)
    end
  end
end
