# frozen_string_literal: true

# Helper for route handling in tests
module RouteTestHelper
  # Mock path helpers for controllers
  def mock_path_helpers
    # Skip organization tenant check for admin controllers
    allow_any_instance_of(ApplicationController).to receive(:load_tenant_from_session)
    # Skip authentication for admin controllers in tests
    allow_any_instance_of(ApplicationController).to receive(:authenticate_user!)
  end

  # Make sure URL helpers work in controller specs
  def set_default_url_options
    @request.host = 'www.example.com' if @request
    # Set default URL options for route helpers
    Rails.application.routes.default_url_options[:host] = 'www.example.com'
  end

  # Helper to add routes needed for the specs - used for specific controller tests
  def setup_test_routes
    Rails.application.routes.clear!

    Rails.application.routes.draw do
      # Authentication routes
      devise_for :users, controllers: { sessions: 'users/sessions' }

      # Base routes
      root 'projects#index'

      # Admin namespace
      namespace :admin do
        get '/dashboard', to: 'dashboard#index', as: 'dashboard'
        resources :organisations, only: [:index]
        resources :users, only: %i[index show new create] do
          member do
            patch :toggle_active
          end
        end
        resources :beusers
      end

      # Direct resource routes
      resources :ticket_priorities
      resources :ticket_statuses
      resources :organisations
      resources :invitations, only: %i[new create destroy]
      resources :memberships, only: %i[index edit update destroy]

      # Organisation routes
      get 'select_organisation', to: 'organisations#select', as: :select_organisation
      post 'set_organisation', to: 'organisations#set', as: :set_organisation

      # Accept invitation routes
      resource :accept_invitation, only: %i[show update] do
        get :success, on: :member
      end

      # Search routes
      get 'power_search', to: 'power_search#index'
      post 'power_search', to: 'power_search#execute'

      # Nested resources
      resources :projects do
        resources :time_sessions
        resources :chats do
          resources :chatposts, only: %i[create destroy]
        end

        resources :project_permissions, only: %i[index create update destroy]

        resources :tickets do
          member do
            post :create_summary
          end
          resources :posts
        end

        resources :notes
        resources :documents do
          member do
            get :download
            post :create_version
            delete :destroy_version
            get :download_plain_text
          end
        end
      end

      # Roles - nested format for most tests
      resources :roles do
        member do
          post :set_default
        end
      end

      # Dashboard routes
      get 'dashboard', to: 'dashboard#index'
    end
  end
end

RSpec.configure do |config|
  config.include RouteTestHelper, type: :controller
  config.include RouteTestHelper, type: :request
  config.include Rails.application.routes.url_helpers

  config.before(:each, type: :controller) do
    mock_path_helpers
    set_default_url_options
    setup_test_routes
  end

  config.before(:each, type: :request) do
    host! 'www.example.com'
    # Only set up routes if they haven't been set up yet
    setup_test_routes unless Rails.application.routes.routes.any? { |r| r.name == 'root' }
  end

  # Controller specs redraw the routes to a minimal TEST set in their before hook (setup_test_routes
  # does routes.clear! + draw). Those test routes also define a `root`, so the request hook above —
  # which skips setup "if a root already exists" — would then leave a later request/component spec
  # running against the test routes, where full app helpers like organisation_project_tickets_path no
  # longer exist. That is an order-dependent flake (only bites when a controller spec runs before a
  # route-needing request/component spec). Restoring the REAL app routes after every controller spec
  # makes the suite order-stable regardless of seed; the next controller spec redraws the test routes
  # again in its own before hook, so nothing a controller spec relies on changes.
  config.after(:each, type: :controller) do
    Rails.application.reload_routes!
  end
end
