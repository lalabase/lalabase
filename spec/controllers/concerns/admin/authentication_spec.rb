# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::Authentication, type: :controller do
  # Anonymous controller to test the concern in isolation.
  # We define admin_log_in_path directly because anonymous controllers
  # don't have access to the application's named route helpers.
  controller(ActionController::Base) do
    include Admin::Authentication

    def admin_log_in_path
      '/admin/log_in'
    end

    def index
      render plain: 'ok'
    end

    def dashboard
      render plain: "Hello #{current_user&.email}"
    end
  end

  before do
    routes.draw do
      get 'anonymous/index' => 'anonymous#index'
      get 'anonymous/dashboard' => 'anonymous#dashboard'
    end
  end

  let(:beuser) { create(:beuser, email: 'admin@example.com', active: true) }

  # ==========================================================================
  # current_user
  # ==========================================================================
  describe '#current_user' do
    context 'when session contains a valid user_id' do
      before { session[:beuser_id] = beuser.id }

      it 'returns the Beuser' do
        get :index
        expect(controller.send(:current_user)).to eq(beuser)
      end

      it 'memoizes the result across multiple calls' do
        get :index
        # First call already happened in the before_action chain.
        # Subsequent calls must not hit the database.
        expect(Beuser).not_to receive(:find_by)
        controller.send(:current_user)
        controller.send(:current_user)
      end
    end

    context 'when session contains an invalid user_id' do
      before { session[:beuser_id] = SecureRandom.uuid }

      it 'returns nil' do
        get :index
        expect(controller.send(:current_user)).to be_nil
      end

      it 'memoizes nil to prevent repeated DB queries' do
        get :index
        # After the request, current_user was already resolved to nil.
        # Subsequent calls must not hit the database again.
        expect(Beuser).not_to receive(:find_by)
        controller.send(:current_user)
        controller.send(:current_user)
      end
    end

    context 'when session has no user_id' do
      it 'returns nil without querying the database' do
        expect(Beuser).not_to receive(:find_by)
        get :index
        expect(controller.send(:current_user)).to be_nil
      end
    end

    context 'when session user_id is an empty string' do
      before { session[:beuser_id] = '' }

      it 'returns nil without querying the database' do
        expect(Beuser).not_to receive(:find_by)
        get :index
        expect(controller.send(:current_user)).to be_nil
      end
    end

    context 'when the Beuser is inactive' do
      let(:inactive_beuser) { create(:beuser, active: false) }

      before { session[:beuser_id] = inactive_beuser.id }

      it 'still returns the Beuser (active filtering is not part of authentication)' do
        get :index
        expect(controller.send(:current_user)).to eq(inactive_beuser)
      end
    end
  end

  # ==========================================================================
  # logged_in?
  # ==========================================================================
  describe '#logged_in?' do
    context 'when current_user is present' do
      before { session[:beuser_id] = beuser.id }

      it 'returns true' do
        get :index
        expect(controller.send(:logged_in?)).to be true
      end
    end

    context 'when current_user is nil' do
      it 'returns false' do
        get :index
        expect(controller.send(:logged_in?)).to be false
      end
    end
  end

  # ==========================================================================
  # require_login (before_action)
  # ==========================================================================
  describe '#require_login' do
    context 'when user is authenticated' do
      before { session[:beuser_id] = beuser.id }

      it 'allows the request to proceed' do
        get :index
        expect(response).to have_http_status(:ok)
        expect(response.body).to eq('ok')
      end
    end

    context 'when user is not authenticated' do
      it 'redirects to admin login path' do
        get :index
        expect(response).to redirect_to('/admin/log_in')
      end

      it 'does not render the action body' do
        get :dashboard
        expect(response.body).not_to include('Hello')
      end
    end

    context 'when session user was deleted between requests' do
      # Another active admin remains: the last one cannot be deleted (Beuser).
      before do
        create(:beuser)
        session[:beuser_id] = beuser.id
        beuser.destroy!
      end

      it 'redirects to admin login path' do
        get :index
        expect(response).to redirect_to('/admin/log_in')
      end
    end

    # D4/D8: authorization is re-checked on EVERY request, so a beuser that was
    # deactivated or demoted after login is thrown out on the next request and
    # the admin key is dropped -- without leaking into any other session key.
    context 'when the beuser is deactivated mid-session (D4)' do
      # Another active admin does it: the last one cannot lose the role (Beuser).
      before do
        create(:beuser)
        session[:beuser_id] = beuser.id
      end

      it 'redirects and clears the admin key' do
        beuser.update!(active: false)

        get :index

        expect(response).to redirect_to('/admin/log_in')
        expect(session[:beuser_id]).to be_blank
      end
    end

    context 'when the beuser is demoted to non-admin mid-session (D8)' do
      # Another active admin does it: the last one cannot lose the role (Beuser).
      before do
        create(:beuser)
        session[:beuser_id] = beuser.id
      end

      it 'redirects and clears the admin key' do
        beuser.update!(role: 'user')

        get :index

        expect(response).to redirect_to('/admin/log_in')
        expect(session[:beuser_id]).to be_blank
      end
    end
  end

  # ==========================================================================
  # require_login with a self-redirecting logged_in? override
  # ==========================================================================
  # Admin::MissionControlController overrides logged_in? to redirect ITSELF
  # (route-generation quirks with Mission Control params). require_login must
  # not then redirect a second time -- the `unless performed?` guard is the only
  # thing preventing a DoubleRenderError there. The default anonymous controller
  # above does NOT override logged_in?, so nothing else exercises this branch:
  # remove the guard and every other spec still passes while /admin/jobs blows up
  # in production for logged-out visitors. This example pins the branch.
  describe '#require_login when logged_in? self-redirects (Mission Control pattern)' do
    controller(ActionController::Base) do
      include Admin::Authentication

      def admin_log_in_path
        '/admin/log_in'
      end

      # Mimics Admin::MissionControlController: performs its own redirect when
      # the visitor is not logged in.
      def logged_in?
        redirect_to('/admin/log_in') unless current_user
        current_user.present?
      end

      def index
        render plain: 'ok'
      end
    end

    before do
      routes.draw { get 'anonymous/index' => 'anonymous#index' }
    end

    it 'redirects exactly once without raising DoubleRenderError' do
      expect { get :index }.not_to raise_error
      expect(response).to redirect_to('/admin/log_in')
    end
  end

  # ==========================================================================
  # helper_method registration
  # ==========================================================================
  describe 'helper_method' do
    it 'registers current_user as a helper method' do
      expect(controller.class._helper_methods).to include(:current_user)
    end
  end
end
