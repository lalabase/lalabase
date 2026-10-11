# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Organisations::NotesController, type: :controller do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project, organisation: organisation)
    end
  end
  let(:note) do
    ActsAsTenant.with_tenant(organisation) do
      create(:note, project: project, organisation: organisation)
    end
  end

  # Helper method to simulate a controller using the refactored code
  def use_refactored_controller
    # Save the original controller class
    original_controller = Organisations::NotesController

    # Read the content of the current controller
    refactored_code = File.read(Rails.root.join('app/controllers/organisations/notes_controller.rb'))

    # Remove the constant if it already exists
    Object.send(:remove_const, 'RefactoredNotesController') if Object.const_defined?('RefactoredNotesController')

    # Create a new class with the refactored code
    Object.const_set('RefactoredNotesController', Class.new(Organisations::BaseController))
    RefactoredNotesController.class_eval(refactored_code.sub('class Organisations::NotesController', 'class RefactoredNotesController'))

    # Replace the controller with the refactored one temporarily
    stub_const('Organisations::NotesController', RefactoredNotesController)

    yield if block_given?

    # Restore the original controller
    stub_const('Organisations::NotesController', original_controller)
    Object.send(:remove_const, 'RefactoredNotesController') if Object.const_defined?('RefactoredNotesController')
  end

  before do
    # Set ActsAsTenant context
    ActsAsTenant.current_tenant = organisation

    # Set up routes for this controller
    routes.draw do
      root 'static#index'
      scope path: '/org/:organisation_id', module: :organisations, as: :organisation do
        resources :projects do
          resources :notes
          resources :knowledge, only: [:index]
        end
      end
      devise_for :users
    end

    # Sign in the user
    sign_in user

    # Create a membership for the user
    ActsAsTenant.with_tenant(organisation) do
      admin_role = create(:role, title: 'admin', organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: admin_role)
    end

    # Set the current organisation
    allow(controller).to receive(:current_organisation).and_return(organisation)

    # Create policy doubles that allow all actions
    policy = double('policy')
    allow(policy).to receive(:area_access?).and_return(true)
    allow(policy).to receive(:show?).and_return(true)
    allow(policy).to receive(:create?).and_return(true)
    allow(policy).to receive(:update?).and_return(true)
    allow(policy).to receive(:destroy?).and_return(true)
    allow(controller).to receive(:policy).and_return(policy)

    # Mock Pundit authorize method to avoid authorization failures.
    # Calling authorize marks the request as authorized for `verify_authorized`.
    allow(controller).to receive(:authorize) do |*_args|
      controller.instance_variable_set(:@_pundit_policy_authorized, true)
      true
    end
    # Bypass Pundit's after_action enforcement entirely for these specs
    allow(controller).to receive(:verify_authorized).and_return(true)
    allow(controller).to receive(:verify_policy_scoped).and_return(true)

    # Mock the policy_scope method
    allow(controller).to receive(:policy_scope) do |*_args|
      controller.instance_variable_set(:@_pundit_policy_scoped, true)
      SmartFolder.none
    end

    # Mock active_member_of_organisation? to return true
    allow_any_instance_of(User).to receive(:active_member_of_organisation?).and_return(true)

    # Default to turbo_frame_request? = true so index doesn't redirect to the
    # unified Knowledge view (notes#index now redirects unless inside a frame).
    allow(controller).to receive(:turbo_frame_request?).and_return(true)
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe 'Refactored controller' do
    it 'includes ObjectListController' do
      use_refactored_controller do
        expect(controller.class.ancestors).to include(ObjectListController)
      end
    end

    it 'defines object_type method' do
      use_refactored_controller do
        expect(controller.send(:object_type)).to eq('Note')
      end
    end

    it 'defines custom template methods' do
      use_refactored_controller do
        # Controller now uses :index for both states (single template handles both)
        expect(controller.send(:with_object_template)).to eq(:index)
        expect(controller.send(:list_only_template)).to eq(:index)
      end
    end
  end

  # The dedicated notes list is gone; index and show hand over to the unified Knowledge view
  # (before_action :redirect_to_knowledge, and the standalone branch in #show). These examples
  # used to assert a 200 plus @selected_object/@selected_note from the old three-column UI and
  # went red on the redirect — they pinned a screen that no longer exists. They now pin the
  # handover, which is the part worth guarding: if it breaks, users land on a dead route
  # instead of their knowledge base.
  describe 'GET #index' do
    it 'hands over to the Knowledge view, filtered to notes' do
      get :index, params: { organisation_id: organisation.id, project_id: project.id }

      expect(response).to redirect_to(
        organisation_project_knowledge_index_path(organisation, project, type: 'note')
      )
    end

    # The note travels with the handover. `notes_path(note_id:)` is the address
    # PowerSearchService#result_link builds for every note hit; until 10.09.2026
    # the redirect passed only the type on, so a note found by search opened as
    # a list with nothing selected. Same shape as #show's handover: type=all, so
    # the reader keeps the whole knowledge base in the list beside the note.
    it 'hands over WITH the preselected note, into the full knowledge list' do
      get :index, params: { organisation_id: organisation.id, project_id: project.id, note_id: note.id }

      expect(response).to redirect_to(
        organisation_project_knowledge_index_path(organisation, project, note_id: note.id, type: 'all')
      )
    end
  end

  describe 'GET #show' do
    # A standalone note link lands in the Knowledge view WITH that note selected — note_id and
    # type=all, not type=note, so the reader keeps the full knowledge base in the list beside it.
    # Pinning both parameters matters: dropping note_id would silently open an empty detail pane.
    it 'hands over to the Knowledge view with the note preselected' do
      get :show, params: { organisation_id: organisation.id, project_id: project.id, id: note.id }

      expect(response).to redirect_to(
        organisation_project_knowledge_index_path(organisation, project, note_id: note.id, type: 'all')
      )
    end

    it 'handles the frame=content parameter correctly' do
      use_refactored_controller do
        # Test with frame=content parameter
        get :show, params: {
          organisation_id: organisation.id,
          project_id: project.id,
          id: note.id,
          frame: 'content'
        }

        expect(response).to have_http_status(:success)
        # Frame content responses are HTML without layout
        expect(response.headers['Content-Type']).to include('text/html')
      end
    end
  end

  describe 'CRUD operations' do
    it 'creates a note successfully with refactored controller' do
      use_refactored_controller do
        # Create a note actor double
        actor = double('actor')
        result = double('result', success?: true)
        allow(actor).to receive(:call).and_return(result)
        allow(actor).to receive(:record).and_return(note)
        allow(Actors::SaveNote).to receive(:new).and_return(actor)

        post :create, params: {
          organisation_id: organisation.id,
          project_id: project.id,
          note: { title: 'Test Note', content: 'Test Content' }
        }

        expect(response).to have_http_status(:redirect)
        # Successful create now redirects into the unified Knowledge view
        expect(response.location).to include(organisation_project_knowledge_index_path(organisation, project))
      end
    end

    it 'updates a note successfully with refactored controller' do
      use_refactored_controller do
        # Create a note actor double
        actor = double('actor')
        result = double('result', success?: true)
        allow(actor).to receive(:call).and_return(result)
        allow(actor).to receive(:record).and_return(note)
        allow(Actors::SaveNote).to receive(:new).and_return(actor)

        # Set the note
        allow(controller).to receive(:set_object).and_return(note)
        controller.instance_variable_set(:@note, note)

        patch :update, params: {
          organisation_id: organisation.id,
          project_id: project.id,
          id: note.id,
          note: { title: 'Updated Note', content: 'Updated Content' },
          format: :html
        }

        expect(response).to have_http_status(:redirect)
        expect(response).to redirect_to(organisation_project_note_path(organisation, project, note))
      end
    end

    # Was asserting a redirect back to /notes — a route that no longer exists — and stubbed
    # set_object twice over so the note was never really destroyed. It now deletes for real and
    # pins the actual landing place: the Knowledge view, filtered to notes.
    it 'deletes the note and returns to the Knowledge view' do
      note # create it before the expectation block

      # without_tenant, because the per-request tenant is cleared after the request and the
      # change{} matcher reads the count a second time — a bare Note.count raises NoTenantSet.
      note_count = -> { ActsAsTenant.without_tenant { Note.count } }

      expect do
        delete :destroy, params: {
          organisation_id: organisation.id,
          project_id: project.id,
          id: note.id,
          format: :html
        }
      end.to change { note_count.call }.by(-1)

      expect(response).to redirect_to(
        organisation_project_knowledge_index_path(organisation, project, type: 'note')
      )
    end
  end
end
