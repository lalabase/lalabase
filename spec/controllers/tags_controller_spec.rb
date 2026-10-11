# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Organisations::TagsController, type: :controller do
  before do
    # Set up routes for this controller
    routes.draw do
      root 'static#index'
      scope path: '/org/:organisation_id', module: :organisations, as: :organisation do
        resources :tags
      end
    end
  end

  # routes.draw replaces the global route set; restore it so request specs that run after
  # this file (defined order) keep their named routes (e.g. project_access_scoping_spec).
  after { Rails.application.reload_routes! }

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

  # Test basic controller setup
  describe 'controller setup' do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user) }

    before do
      sign_in user
      ActsAsTenant.current_tenant = organisation

      # Mock everything needed to bypass complex dependencies
      allow(controller).to receive(:current_organisation).and_return(organisation)
      allow(controller).to receive(:set_organisation).and_return(true)
      allow(controller).to receive(:set_current_membership).and_return(true)
      allow(controller).to receive(:policy_scope).and_return(Tag.none)
      allow(controller).to receive(:authorize).and_return(true)
      allow(controller).to receive(:verify_authorized).and_return(true)
      allow(controller).to receive(:verify_policy_scoped).and_return(true)
      # allow(controller).to receive(:sort_collection).and_return(Tag.none)
      allow(controller).to receive(:all_taggable_items).and_return([])

      controller.instance_variable_set(:@organisation, organisation)
      controller.instance_variable_set(:@current_organisation, organisation)
    end

    after do
      ActsAsTenant.current_tenant = nil
    end

    it 'has the correct controller class' do
      expect(controller).to be_a(Organisations::TagsController)
    end

    it 'responds to index action' do
      expect(controller).to respond_to(:index)
    end

    # NOTE: Full action testing requires complex mocking of Sortable, Pageable, and Searchable modules
    # This is skipped to focus on the core controller name fix
  end
end
