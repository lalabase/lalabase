# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Organisations::DocumentsController, type: :controller do
  before do
    # Set up routes for this controller
    routes.draw do
      root 'static#index'
      scope path: '/org/:organisation_id', module: :organisations, as: :organisation do
        resources :projects do
          resources :documents do
            member do
              get :download
              post :create_version
              delete :destroy_version
              get :download_plain_text
            end
          end
        end
      end
    end
  end

  # Test constants and class methods - these don't require authentication
  describe 'class attributes and constants' do
    it 'has setup_sortable with Document model' do
      # Verify that sortable columns are set up correctly
      expect(Organisations::DocumentsController.sortable_model_class).to eq(Document)
      expect(Organisations::DocumentsController.default_sort_column).to eq('documents.created_at')
    end

    it 'has additional sortable columns' do
      expect(Organisations::DocumentsController.sortable_columns_list).to include('document_versions.title')
      expect(Organisations::DocumentsController.sortable_columns_list).to include('users.email')
    end

    it 'has pagination set up with items_per_page' do
      expect(Organisations::DocumentsController.default_per_page).to eq(5)
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

  # Test controller private methods with minimal auth mocking
  describe 'private methods' do
    let(:organisation) { create(:organisation) }
    let(:project) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation)
      end
    end
    let(:user) { create(:user) }
    let(:document) do
      ActsAsTenant.with_tenant(organisation) do
        create(:document, project: project)
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

      # Mock project setup and authorization
      allow(controller).to receive(:set_project).and_return(project)
      allow(controller).to receive(:authorize_project_access!).and_return(true)
      allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                         project_id: project.id
                                                       ))
      controller.instance_variable_set(:@project, project)
    end

    after do
      ActsAsTenant.current_tenant = nil
    end

    describe '#set_documents' do
      it 'assigns documents for the project' do
        # Create a document for the project that should be found
        document # Create the document

        # Allow access to Project.find
        allow(Project).to receive(:find).and_return(project)

        # Configure controller to have proper mocked methods for find_documents
        allow(controller).to receive(:find_documents).and_call_original
        allow(controller).to receive(:sort_params).and_return(
          ActionController::Parameters.new(column: 'created_at', direction: 'desc').permit!
        )

        # Call the method
        controller.send(:set_documents)

        # Verify that documents are assigned
        expect(controller.instance_variable_get(:@documents)).not_to be_nil
      end
    end

    describe '#set_document' do
      it 'finds the document by id' do
        # Mock params with document id
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           project_id: project.id,
                                                           id: document.id
                                                         ))

        # Call the method
        controller.send(:set_document)

        # Verify that document is assigned
        expect(controller.instance_variable_get(:@document)).to eq(document)
      end

      it 'redirects if document not found' do
        # Mock params with non-existent document id
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           project_id: project.id,
                                                           id: 'non-existent-id'
                                                         ))

        # Set up flash and redirect expectations
        expect(controller).to receive(:flash).and_return(alert: nil)
        expect(controller).to receive(:redirect_to).with(organisation_project_documents_path(organisation, project))

        # Call the method
        controller.send(:set_document)
      end
    end

    describe '#document_params' do
      it 'permits the correct parameters' do
        # Mock params with document attributes
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           document: {
                                                             document_versions_attributes: {
                                                               '0' => {
                                                                 document_version_file: 'file',
                                                                 create_summary: true,
                                                                 title: 'Test Document',
                                                                 description: 'Description'
                                                               }
                                                             }
                                                           }
                                                         ))

        # Call the method
        result = controller.send(:document_params)

        # Verify permitted parameters
        expect(result.to_h).to include(
          'document_versions_attributes' => {
            '0' => {
              'document_version_file' => 'file',
              'create_summary' => true,
              'title' => 'Test Document',
              'description' => 'Description'
            }
          }
        )
      end
    end

    describe '#version_params' do
      it 'permits the correct parameters' do
        # Mock params with version attributes
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           document_version: {
                                                             title: 'Version Title',
                                                             description: 'Version Description',
                                                             document_version_file: 'file',
                                                             create_summary: true
                                                           }
                                                         ))

        # Call the method
        result = controller.send(:version_params)

        # Verify permitted parameters
        expect(result.to_h).to include(
          'title' => 'Version Title',
          'description' => 'Version Description',
          'document_version_file' => 'file',
          'create_summary' => true
        )
      end
    end
  end
end
