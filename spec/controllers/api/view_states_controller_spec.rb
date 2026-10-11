# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::ViewStatesController, type: :controller do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation)
    end
  end

  around do |example|
    ActsAsTenant.with_tenant(organisation) do
      example.run
    end
  end

  before do
    # Minimal routes for this controller in isolation
    routes.draw do
      namespace :api do
        resources :view_states, only: %i[show update]
      end
      devise_for :users
      root 'static#index'
    end

    # Set up the membership and authentication
    membership # trigger creation
    session[:current_organisation_id] = organisation.id
    sign_in user

    # Mock the controller methods to provide tenant context
    allow(controller).to receive(:current_organisation).and_return(organisation)
    allow(controller).to receive(:current_user).and_return(user)

    # Set the tenant globally for the test
    ActsAsTenant.current_tenant = organisation

    # Mock the problematic method to use tenant context
    allow(controller).to receive(:find_or_initialize_view_state) do
      ActsAsTenant.with_tenant(organisation) do
        viewable = if controller.params[:viewable_type] && controller.params[:viewable_id]
                     controller.params[:viewable_type].constantize.find(controller.params[:viewable_id])
                   else
                     organisation
                   end

        ViewState.find_or_initialize_by(
          user: user,
          key: controller.params[:id],
          viewable: viewable,
          organisation: organisation
        )
      end
    end
  end

  describe 'GET #show' do
    context 'when view state exists' do
      let!(:view_state) do
        ActsAsTenant.with_tenant(organisation) do
          create(:view_state,
                 user: user,
                 key: 'test_accordion',
                 viewable: organisation,
                 organisation: organisation,
                 state: { 'expanded' => true })
        end
      end

      it 'returns the existing state' do
        get :show, params: { id: 'test_accordion' }, format: :json

        expect(response).to have_http_status(:success)
        json = JSON.parse(response.body)
        expect(json['state']).to eq({ 'expanded' => true })
      end
    end

    context 'when view state does not exist' do
      it 'returns empty state' do
        get :show, params: { id: 'non_existent' }, format: :json

        expect(response).to have_http_status(:success)
        json = JSON.parse(response.body)
        expect(json['state']).to eq({})
      end
    end
  end

  describe 'PUT #update' do
    context 'when view state exists' do
      let!(:view_state) do
        ActsAsTenant.with_tenant(organisation) do
          create(:view_state,
                 user: user,
                 key: 'test_accordion',
                 viewable: organisation,
                 organisation: organisation,
                 state: { 'expanded' => true })
        end
      end

      it 'updates the state' do
        put :update, params: {
          id: 'test_accordion',
          state: { 'expanded' => false, 'height' => '300px' }
        }, format: :json

        expect(response).to have_http_status(:success)

        view_state.reload
        expect(view_state.state).to eq({
                                         'expanded' => 'false',
                                         'height' => '300px'
                                       })
      end

      it 'merges with existing state' do
        view_state.update(state: { 'expanded' => true, 'width' => '100%' })

        put :update, params: {
          id: 'test_accordion',
          state: { 'expanded' => false }
        }, format: :json

        view_state.reload
        expect(view_state.state).to eq({
                                         'expanded' => 'false',
                                         'width' => '100%'
                                       })
      end
    end

    context 'when view state does not exist' do
      it 'creates a new view state' do
        expect do
          put :update, params: {
            id: 'new_accordion',
            state: { 'expanded' => true }
          }, format: :json
        end.to change { ActsAsTenant.with_tenant(organisation) { ViewState.count } }.by(1)

        expect(response).to have_http_status(:success)

        ActsAsTenant.with_tenant(organisation) do
          new_state = ViewState.last
          expect(new_state.user).to eq(user)
          expect(new_state.key).to eq('new_accordion')
          expect(new_state.state).to eq({ 'expanded' => 'true' })
        end
      end
    end

    context 'with custom viewable' do
      let(:project) do
        ActsAsTenant.with_tenant(organisation) do
          create(:project, organisation: organisation)
        end
      end

      it 'uses the specified viewable' do
        put :update, params: {
          id: 'project_accordion',
          viewable_type: 'Project',
          viewable_id: project.id,
          state: { 'expanded' => true }
        }, format: :json

        expect(response).to have_http_status(:success)

        ActsAsTenant.with_tenant(organisation) do
          view_state = ViewState.last
          expect(view_state.viewable).to eq(project)
        end
      end
    end
  end
end
