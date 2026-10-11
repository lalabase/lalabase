# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Organisations::NotesController, type: :controller do
  before do
    # Set up routes for this controller
    routes.draw do
      root 'static#index'
      scope path: '/org/:organisation_id', module: :organisations, as: :organisation do
        resources :projects do
          resources :notes
        end
      end
    end
  end

  # Test constants and class methods - these don't require authentication
  describe 'class attributes and constants' do
    it 'has setup_sortable with Note model' do
      # Verify that sortable columns are set up correctly
      expect(Organisations::NotesController.sortable_model_class).to eq(Note)
    end

    it 'has pagination set up with items_per_page' do
      expect(Organisations::NotesController.default_per_page).to eq(5)
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
      get :index, params: { organisation_id: '123', project_id: '456' }
      expect(response).to be_redirect
    end
  end
end
