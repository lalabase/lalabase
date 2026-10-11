# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Organisations::PostsController, type: :controller do
  before do
    # Set up routes for this controller
    routes.draw do
      root 'static#index'
      scope path: '/org/:organisation_id', module: :organisations, as: :organisation do
        resources :projects do
          resources :tickets do
            resources :posts, only: %i[create show edit update destroy]
          end
        end
      end
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
      post :create, params: { organisation_id: '123', project_id: '456', ticket_id: '789' }
      expect(response).to be_redirect
    end
  end

  # Test controller private methods with minimal auth mocking
  describe 'private methods' do
    let(:organisation) { create(:organisation) }
    let(:project) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation)
      end
    end
    let(:user) { create(:user) }
    let(:ticket) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation)
      end
    end
    let(:post_obj) do
      ActsAsTenant.with_tenant(organisation) do
        create(:post, ticket: ticket, user: user, organisation: organisation)
      end
    end

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
      allow(controller).to receive(:set_organisation).and_return(true)
      allow(controller).to receive(:set_current_membership).and_return(true)

      # Set organisation instance variables
      controller.instance_variable_set(:@organisation, organisation)
      controller.instance_variable_set(:@current_organisation, organisation)

      # Mock authorization by default
      allow(controller).to receive(:authorize).and_return(true)

      # Mock project
      allow(controller).to receive(:set_project).and_return(project)
      controller.instance_variable_set(:@project, project)
    end

    after do
      ActsAsTenant.current_tenant = nil
    end

    describe '#post_params' do
      it 'permits the correct parameters' do
        # Mock params with post attributes
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           post: {
                                                             content: 'Test content',
                                                             post_documents_attributes: {
                                                               '0' => {
                                                                 id: 1,
                                                                 post_document_file: 'file',
                                                                 _destroy: '0'
                                                               }
                                                             },
                                                             post_document_files: %w[file1 file2]
                                                           }
                                                         ))

        # Call the method
        result = controller.send(:post_params)

        # Verify permitted parameters
        expect(result.to_h).to include('content' => 'Test content')
        expect(result.to_h).to include('post_documents_attributes')

        # Verify post_document_files is removed (as per the controller code)
        expect(result.to_h).not_to include('post_document_files')
      end
    end
  end
end
