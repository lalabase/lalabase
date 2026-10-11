# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Organisations::ProjectsController, type: :controller do
  before do
    Rails.application.routes.draw do
      namespace :organisations do
        resources :projects
      end
    end
  end

  after do
    Rails.application.reload_routes!
  end
  # Test constants and class methods - these don't require authentication
  describe 'class attributes and constants' do
    it 'has SORTABLE_COLUMNS set to Project column names' do
      expect(Organisations::ProjectsController::SORTABLE_COLUMNS).to eq(Project.column_names)
    end

    it 'has default_sort_column set to projects.created_at' do
      expect(Organisations::ProjectsController.default_sort_column).to eq('projects.created_at')
    end
  end

  # Test controller instance methods that don't require authentication
  describe '#sort_params' do
    let(:controller) { Organisations::ProjectsController.new }
    let(:organisation) { create(:organisation) }
    let(:project) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation)
      end
    end

    it 'permits specified parameters' do
      params = ActionController::Parameters.new(
        sort: { column: 'name', direction: 'asc', page: 1, project_id: project.id }
      )
      allow(controller).to receive(:params).and_return(params)

      expect(controller.sort_params.to_h).to eq(
        { 'column' => 'name', 'direction' => 'asc', 'page' => 1, 'project_id' => project.id }
      )
    end

    it 'filters out non-permitted parameters' do
      # No need to reference project for this test
      params = ActionController::Parameters.new(
        sort: { column: 'name', direction: 'asc', unauthorized: 'value' }
      )
      allow(controller).to receive(:params).and_return(params)

      expect(controller.sort_params.to_h).to eq(
        { 'column' => 'name', 'direction' => 'asc' }
      )
    end
  end

  # Test authentication without hitting controller actions
  describe 'authentication' do
    let(:organisation) { create(:organisation) }
    let(:admin_user) { create(:user) }

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
end
