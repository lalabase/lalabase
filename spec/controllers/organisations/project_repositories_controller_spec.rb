# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Organisations::ProjectRepositoriesController, type: :controller do
  after(:all) { Rails.application.reload_routes! }

  before do
    routes.draw do
      root 'static#index'
      scope path: '/org/:organisation_id', module: :organisations, as: :organisation do
        resources :projects do
          resources :project_repositories, only: %i[index new create destroy]
        end
      end
    end
  end

  let(:organisation) { create(:organisation, code_indexing_enabled: true) } # per-org beta feature on
  let(:project)      { create(:project, organisation: organisation) }
  let(:admin_role)   { create(:role, title: 'account_admin', organisation: organisation) }
  let(:admin_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    user
  end

  before do
    @request.env['devise.mapping'] = Devise.mappings[:user]
    ActsAsTenant.test_tenant = organisation
    ActsAsTenant.current_tenant = organisation
    allow(controller).to receive(:current_user).and_return(admin_user)
    allow(controller).to receive(:user_signed_in?).and_return(true)
    allow(controller).to receive(:authenticate_user!).and_return(true)
    allow(controller).to receive(:set_organisation) do
      ActsAsTenant.current_tenant = organisation
      controller.instance_variable_set(:@current_organisation, organisation)
    end
    allow(controller).to receive(:set_current_membership).and_return(true)
    controller.instance_variable_set(:@current_organisation, organisation)
    controller.instance_variable_set(:@current_membership,
                                     organisation.memberships.find_by(user: admin_user))
  end

  after do
    ActsAsTenant.test_tenant = nil
    ActsAsTenant.current_tenant = nil
  end

  let(:valid_metadata) do
    { provider_repo_id: '12345', full_name: 'acme/backend', default_branch: 'main', private: true }
  end

  def stub_client(token_ok: true, metadata: valid_metadata, raise_class: nil, raise_msg: 'err')
    client = instance_double(Lalabase::Github::Client)
    if raise_class
      allow(client).to receive(:validate_token!).and_raise(raise_class, raise_msg)
    else
      allow(client).to receive(:validate_token!).and_return(login: 'alice', id: 1) if token_ok
      allow(client).to receive(:fetch_repo_metadata!).and_return(metadata)
    end
    allow(Lalabase::Github::Client).to receive(:new).and_return(client)
    client
  end

  describe 'POST #create' do
    let(:valid_params) do
      { organisation_id: organisation.id, project_id: project.id,
        project_repository: { full_name: 'acme/backend', access_token: 'ghp_valid' } }
    end

    context 'happy path' do
      before { stub_client }

      it 'persists the repository' do
        expect { post :create, params: valid_params }.to change(ProjectRepository, :count).by(1)
      end

      it 'overwrites client-supplied metadata with the GitHub response' do
        params = valid_params.deep_dup
        params[:project_repository][:full_name] = 'acme/old-name' # user lies about the name
        post :create, params: params
        repo = ProjectRepository.last
        # provider_repo_id and default_branch come from the API, not the form
        expect(repo.provider_repo_id).to eq('12345')
        expect(repo.default_branch).to eq('main')
        # full_name is canonicalised from the API too
        expect(repo.full_name).to eq('acme/backend')
      end

      it 'attributes the connection to the current user' do
        post :create, params: valid_params
        expect(ProjectRepository.last.connected_by_user).to eq(admin_user)
      end

      it 'sets connected_at to roughly now' do
        post :create, params: valid_params
        expect(ProjectRepository.last.connected_at).to be_within(5.seconds).of(Time.current)
      end

      it 'redirects to the index with a success flash' do
        post :create, params: valid_params
        expect(response).to redirect_to(
          "/org/#{organisation.id}/projects/#{project.id}/project_repositories"
        )
        expect(flash[:notice]).to include('acme/backend')
      end
    end

    context 'when GitHub returns 401 (invalid token)' do
      before { stub_client(raise_class: Lalabase::Github::Client::AuthError, raise_msg: 'Bad credentials') }

      it 'does NOT persist the repository' do
        expect { post :create, params: valid_params }.not_to change(ProjectRepository, :count)
      end

      it 'returns unprocessable_content status' do
        post :create, params: valid_params
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'shows the actionable "invalid/expired token" message on :base' do
        post :create, params: valid_params
        repo = assigns(:repository)
        expect(repo.errors[:base])
          .to include(I18n.t('views.organisations.project_repositories.connect_errors.auth'))
      end
    end

    context 'when GitHub returns 404 (repo not found)' do
      before { stub_client(raise_class: Lalabase::Github::Client::NotFoundError, raise_msg: 'Not Found') }

      # 404 means EITHER a wrong name OR a private repo the token can't see. The
      # message must point at the token's repo access, not only the spelling —
      # otherwise a correct name + wrong PAT scope reads as "you typed it wrong".
      it 'shows the actionable name-or-access message on :base' do
        post :create, params: valid_params
        repo = assigns(:repository)
        expect(repo.errors[:base])
          .to include(I18n.t('views.organisations.project_repositories.connect_errors.not_found'))
      end
    end

    context 'when GitHub returns 403 (insufficient scope)' do
      before { stub_client(raise_class: Lalabase::Github::Client::InvalidScopeError, raise_msg: 'no scope') }

      it 'shows the actionable "needs Contents: Read" message on :base' do
        post :create, params: valid_params
        repo = assigns(:repository)
        expect(repo.errors[:base])
          .to include(I18n.t('views.organisations.project_repositories.connect_errors.insufficient_scope'))
      end
    end

    context 'when GitHub is rate-limited' do
      before { stub_client(raise_class: Lalabase::Github::Client::RateLimitError, raise_msg: 'rate limit') }

      it 'attaches an error on :base (not on a specific field)' do
        post :create, params: valid_params
        repo = assigns(:repository)
        expect(repo.errors[:base]).to be_present
      end
    end

    context 'when authorization is denied' do
      let(:standard_role) { create(:role, title: 'Standard', organisation: organisation, is_default: true) }
      let(:standard_user) do
        u = create(:user)
        create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
        u
      end

      before do
        allow(controller).to receive(:current_user).and_return(standard_user)
        stub_client
      end

      it 'redirects (Pundit handler catches the NotAuthorizedError) with an alert' do
        post :create, params: valid_params
        expect(response).to be_redirect
        expect(flash[:alert]).to be_present
      end

      it 'does NOT persist the repository' do
        expect { post :create, params: valid_params }.not_to change(ProjectRepository, :count)
      end
    end
  end

  describe 'GET #index' do
    it 'renders successfully for an admin user' do
      get :index, params: { organisation_id: organisation.id, project_id: project.id }
      expect(response).to have_http_status(:ok)
    end

    it 'only assigns repositories belonging to the current project' do
      mine    = create(:project_repository, project: project, organisation: organisation, full_name: 'me/here')
      other_p = create(:project, organisation: organisation)
      _theirs = create(:project_repository, project: other_p, organisation: organisation, full_name: 'them/there')

      get :index, params: { organisation_id: organisation.id, project_id: project.id }
      expect(assigns(:repositories)).to contain_exactly(mine)
    end

    it 'orders repositories by created_at (stable list rendering)' do
      first  = create(:project_repository, project: project, organisation: organisation,
                                           full_name: 'a/first', created_at: 2.days.ago)
      second = create(:project_repository, project: project, organisation: organisation,
                                           full_name: 'b/second', created_at: 1.day.ago)
      get :index, params: { organisation_id: organisation.id, project_id: project.id }
      expect(assigns(:repositories).to_a).to eq([first, second])
    end

    # Repos connected before the webhook_secret column existed have a nil secret;
    # index backfills it (in the action, not the view) so the connect component
    # can render a copyable value.
    it 'backfills a missing webhook secret on legacy repositories' do
      repo = create(:project_repository, project: project, organisation: organisation, full_name: 'legacy/repo')
      repo.update_column(:webhook_secret, nil)

      get :index, params: { organisation_id: organisation.id, project_id: project.id }

      expect(repo.reload.webhook_secret).to be_present
    end
  end

  describe 'GET #new' do
    it 'renders successfully for an admin user' do
      get :new, params: { organisation_id: organisation.id, project_id: project.id }
      expect(response).to have_http_status(:ok)
    end

    it 'assigns a fresh, unsaved ProjectRepository pre-set to provider github' do
      get :new, params: { organisation_id: organisation.id, project_id: project.id }
      repo = assigns(:repository)
      expect(repo).to be_a(ProjectRepository)
      expect(repo).not_to be_persisted
      expect(repo.provider).to eq('github')
    end

    it 'denies access to standard users (no chat-write permission)' do
      standard_role = create(:role, title: 'Standard', organisation: organisation, is_default: true)
      standard_user = create(:user).tap do |u|
        create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
      end
      allow(controller).to receive(:current_user).and_return(standard_user)

      get :new, params: { organisation_id: organisation.id, project_id: project.id }
      expect(response).to be_redirect
      expect(flash[:alert]).to be_present
    end
  end

  describe 'POST #create mass-assignment defense' do
    before { stub_client }

    let(:malicious_params) do
      { organisation_id: organisation.id, project_id: project.id,
        project_repository: {
          full_name: 'acme/backend',
          access_token: 'ghp_valid',
          provider: 'gitlab', # try to switch provider
          provider_repo_id: 'spoofed-99999', # try to forge GitHub id
          default_branch: 'attacker-controlled-branch',
          organisation_id: SecureRandom.uuid # try to inject foreign tenant
        } }
    end

    it 'ignores the params-provided provider (controller always sets github)' do
      post :create, params: malicious_params
      expect(ProjectRepository.last.provider).to eq('github')
    end

    it 'ignores the params-provided provider_repo_id (uses GitHub API value)' do
      post :create, params: malicious_params
      expect(ProjectRepository.last.provider_repo_id).to eq('12345')
    end

    it 'ignores the params-provided default_branch (uses GitHub API value)' do
      post :create, params: malicious_params
      expect(ProjectRepository.last.default_branch).to eq('main')
    end

    it 'ignores the params-provided organisation_id (controller sets it from session)' do
      post :create, params: malicious_params
      expect(ProjectRepository.last.organisation_id).to eq(organisation.id)
    end
  end

  describe 'DELETE #destroy' do
    let!(:repository) do
      create(:project_repository, project: project, organisation: organisation,
                                  full_name: 'acme/legacy')
    end

    it 'destroys the repository' do
      expect do
        delete :destroy, params: { organisation_id: organisation.id, project_id: project.id, id: repository.id }
      end.to change(ProjectRepository, :count).by(-1)
    end

    it 'redirects to index with a notice containing the repo name' do
      delete :destroy, params: { organisation_id: organisation.id, project_id: project.id, id: repository.id }
      expect(response).to be_redirect
      expect(flash[:notice]).to include('acme/legacy')
    end

    it 'cannot find a repo belonging to a different project (tenant scoping)' do
      foreign_project = create(:project, organisation: organisation)
      expect do
        delete :destroy, params: { organisation_id: organisation.id,
                                   project_id: foreign_project.id, id: repository.id }
      end.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
