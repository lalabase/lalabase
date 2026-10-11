# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Organisations::AiSettingsController, type: :controller do
  let(:organisation) { create(:organisation) }
  let(:admin_role) do
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, title: 'account_admin', organisation: organisation)
      allow(role).to receive(:account_admin?).and_return(true)
      role
    end
  end
  let(:user_role) do
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, title: 'Standard-Benutzer', organisation: organisation, is_default: true)
      allow(role).to receive(:account_admin?).and_return(false)
      role
    end
  end

  let(:admin_user) { create(:user) }
  let(:regular_user) { create(:user) }

  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin_user, organisation: organisation, role: admin_role, active: true)
    end
  end
  let!(:user_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: regular_user, organisation: organisation, role: user_role, active: true)
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation

    # Set up routes for this controller
    routes.draw do
      root 'static#index'
      scope path: '/org/:organisation_id', module: :organisations, as: :organisation do
        resource :ai_settings, only: %i[show update] do
          post :test_connection, on: :member
        end
      end
      devise_for :users
    end

    # Properly set the organisation and current user context
    allow(controller).to receive(:current_organisation).and_return(organisation)
    allow(controller).to receive(:set_organisation).and_call_original
    controller.instance_variable_set(:@organisation, organisation)
    controller.instance_variable_set(:@current_organisation, organisation)

    # Bypass active-membership guard in BaseController (membership lookup needs
    # tenant + current_user wiring that we already mock per-context). Also
    # ensure ActsAsTenant.current_tenant is set so policies can resolve.
    allow(controller).to receive(:set_current_membership) do
      ActsAsTenant.current_tenant = organisation
    end
    allow(controller).to receive(:set_organisation) do
      controller.instance_variable_set(:@organisation, organisation)
      controller.instance_variable_set(:@current_organisation, organisation)
      ActsAsTenant.current_tenant = organisation
    end

    # Mock the Pundit user method
    allow(controller).to receive(:pundit_user).and_return(nil)
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe 'GET #show' do
    context 'when user is account admin' do
      before do
        sign_in admin_user
        allow(controller).to receive(:current_membership).and_return(admin_membership)
        allow(controller).to receive(:pundit_user).and_return(admin_user)
        controller.instance_variable_set(:@current_membership, admin_membership)

        # Mock the user's role checking methods for admin access
        allow(admin_user).to receive(:account_admin_in?).and_return(true)
        allow(admin_user).to receive(:role_in_organisation).with(organisation).and_return(admin_role)

        # Mock AiCredential methods to avoid database queries
        credentials_mock = double('credentials')
        allow(credentials_mock).to receive(:group_by).and_return({})
        allow(AiCredential).to receive(:enabled).and_return(credentials_mock)
        # S1: the controller builds the dropdown via provider_options_for_select
        # (implemented providers only).
        allow(AiCredential).to receive(:provider_options_for_select).and_return([%w[OpenAI openai]])

        # Mock organisation methods
        allow(organisation).to receive(:ai_provider).and_return('openai')
        allow(organisation).to receive(:has_own_ai_credentials?).and_return(false)
        allow(organisation).to receive(:masked_ai_token).and_return(nil)
        allow(organisation).to receive(:ai_organization_id).and_return(nil)
        allow(organisation).to receive(:ai_usage_stats).and_return({})

        # #find_system_credential_for_provider was stubbed here until S7. It is gone with
        # the form that used it — the resolved system credential was one of the five keys
        # of @current_settings, and only the radio ever read it.

        # authorize_ai_settings runs normally — admin user has access
      end

      it 'allows access to AI settings' do
        get :show, params: { organisation_id: organisation.id }
        expect(response).to have_http_status(:success)
      end

      # ⚠️ Narrowed by S7 (doc/ki_bereich_navigation_plan.md, E6-A). This used to assert
      # @available_system_credentials, @provider_options and @current_settings — the
      # three assigns the two-axis form read. All three left with that form: the provider
      # list and the masked token belong to "Eigene Konfiguration" now (pinned in
      # spec/requests/organisations/ai_configuration_*), and the system-credential list
      # had no reader left at all once the radio was gone. What this page still owns is
      # the package catalogue.
      it 'loads the package catalogue this page is now about' do
        get :show, params: { organisation_id: organisation.id }
        expect(assigns(:package_catalogue)).not_to be_nil
        expect(assigns(:packages)).not_to be_nil
      end
    end

    context 'when user is regular user' do
      before do
        sign_in regular_user
        allow(controller).to receive(:current_membership).and_return(user_membership)
        allow(controller).to receive(:pundit_user).and_return(regular_user)
        controller.instance_variable_set(:@current_membership, user_membership)

        # Mock the user's role checking methods for non-admin access
        allow(regular_user).to receive(:account_admin_in?).and_return(false)
        allow(regular_user).to receive(:role_in_organisation).with(organisation).and_return(user_role)
      end

      it 'denies access with Pundit error' do
        # Don't skip authorization for regular users - let Pundit do its work
        get :show, params: { organisation_id: organisation.id }
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to be_present
      end
    end

    context 'when user is not logged in' do
      it 'redirects to login' do
        # Mock authentication to return false
        allow(controller).to receive(:authenticate_user!).and_call_original
        allow(controller).to receive(:user_signed_in?).and_return(false)
        allow(controller).to receive(:current_user).and_return(nil)

        get :show, params: { organisation_id: organisation.id }
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  # ⚠️ `PATCH #update` is gone from this controller with S7 (E6-A), and so is its route.
  # It was the third and last unprotected write site of the AI protocol: a bare
  # @organisation.update that wrote four columns, dropped the key as a side effect (L3)
  # and left no trace. Its three examples are not deleted, they MOVED with the write —
  # the happy path and the authorisation half to
  # spec/requests/organisations/ai_configuration_spec.rb, the cross-tenant half to
  # spec/requests/organisations/ai_settings_controller_spec.rb, and that the route no
  # longer answers PATCH is pinned positively in the former.

  describe 'POST #test_connection' do
    let(:test_params) do
      {
        organisation_id: organisation.id,
        provider: 'openai'
      }
    end

    context 'when user is account admin' do
      before do
        sign_in admin_user
        allow(controller).to receive(:current_membership).and_return(admin_membership)
        allow(controller).to receive(:pundit_user).and_return(admin_user)
        controller.instance_variable_set(:@current_membership, admin_membership)

        # Mock the user's role checking methods for admin access
        allow(admin_user).to receive(:account_admin_in?).and_return(true)
        allow(admin_user).to receive(:role_in_organisation).with(organisation).and_return(admin_role)

        allow(organisation).to receive(:ai_provider).and_return('openai')
        allow(organisation).to receive(:name).and_return('Test Org')

        # authorize_ai_settings runs normally — admin user has access
      end

      # ⚠️ The seam changed with S7 (gap L6): Factory.chat_probe, not Factory.for_chat.
      # The rescue chain that used to live in this action is gone with it — two of its
      # branches WERE the gates, and the remaining outcomes are now classified once, in
      # Lalabase::Llm::ConnectionCheck, so both buttons that probe answer alike.
      it 'reports success when the seam connects' do
        provider = instance_double(Lalabase::Llm::OpenAiProvider, connectivity_check: true)
        allow(Lalabase::Llm::Factory).to receive(:chat_probe).with(organisation).and_return(provider)

        post :test_connection, params: test_params

        expect(response).to redirect_to(organisation_ai_settings_path(organisation))
        expect(flash[:notice]).to eq(
          I18n.t('flash.ai_settings.connection_success', provider: AiCredential.provider_display_names['openai'])
        )
      end

      it 'reports no models when the endpoint answers empty' do
        provider = instance_double(Lalabase::Llm::OpenAiProvider, connectivity_check: false)
        allow(Lalabase::Llm::Factory).to receive(:chat_probe).with(organisation).and_return(provider)

        post :test_connection, params: test_params

        expect(flash[:alert]).to eq(I18n.t('flash.ai_settings.connection_no_models'))
      end

      # ⚠️ INVERTED by S7. This example used to assert the opt-in hint, because the probe
      # ran through the gated seam and could not answer for a switched-off organisation
      # at all. That was L6: "erst konfigurieren, dann anschalten" is the natural order,
      # so the button declined exactly when it was needed. It answers now, and what it
      # answers is a statement about the ACCESS.
      it 'answers for a switched-off organisation instead of naming the opt-in' do
        provider = instance_double(Lalabase::Llm::OpenAiProvider, connectivity_check: true)
        allow(Lalabase::Llm::Factory).to receive(:chat_probe).and_return(provider)

        post :test_connection, params: test_params

        expect(flash[:alert]).to be_blank
        expect(flash[:notice]).to be_present
      end

      # The provider LABEL, not the routing key: this is the same message both probing
      # buttons render, and "OpenAI (GPT)" is what the customer sees everywhere else.
      it 'reports no client when no credential resolves' do
        allow(Lalabase::Llm::Factory).to receive(:chat_probe)
          .and_raise(Lalabase::Llm::Factory::MissingCredentialError, 'no cred')

        post :test_connection, params: test_params

        expect(flash[:alert]).to eq(
          I18n.t('flash.ai_settings.no_client', provider: AiCredential.provider_display_names['openai'])
        )
      end

      it 'reports a connection error with the reason when the probe itself raises' do
        # Provider maps the vendor 401 to AuthError; it must surface as the specific
        # connection_error (with the message), not the generic no_client copy.
        provider = instance_double(Lalabase::Llm::OpenAiProvider)
        allow(provider).to receive(:connectivity_check).and_raise(Lalabase::Llm::Provider::AuthError, '401 bad key')
        allow(Lalabase::Llm::Factory).to receive(:chat_probe).with(organisation).and_return(provider)

        post :test_connection, params: test_params

        expect(flash[:alert]).to eq(I18n.t('flash.ai_settings.connection_error', error: '401 bad key'))
      end
    end

    context 'when user is regular user' do
      before do
        sign_in regular_user
        allow(controller).to receive(:current_membership).and_return(user_membership)
        allow(controller).to receive(:pundit_user).and_return(regular_user)
        controller.instance_variable_set(:@current_membership, user_membership)

        # Mock the user's role checking methods for non-admin access
        allow(regular_user).to receive(:account_admin_in?).and_return(false)
        allow(regular_user).to receive(:role_in_organisation).with(organisation).and_return(user_role)
      end

      it 'denies access with Pundit error' do
        # Don't skip authorization for regular users - let Pundit do its work
        post :test_connection, params: test_params
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to be_present
      end
    end
  end
end
