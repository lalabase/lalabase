# frozen_string_literal: true

require 'rails_helper'

# Covers rotating a connected repo's access token (PATCH update_token) — the
# recovery path for an expired PAT: validates the new token against GitHub, keeps
# the existing index, and is gated to write users.
RSpec.describe 'Project repository token update', type: :request do
  let(:organisation) { create(:organisation, code_indexing_enabled: true) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:repository) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_repository, project: project, organisation: organisation,
                                  full_name: 'acme/x', provider_repo_id: 'ext-42',
                                  default_branch: 'main', access_token: 'ghp_old_expired')
    end
  end

  let(:new_token) { 'ghp_fresh_valid_token' }
  let(:github_client) { instance_double(Lalabase::Github::Client) }

  def update_token_path
    update_token_organisation_project_project_repository_path(organisation, project, repository)
  end

  def membership_for(user, role)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  # GitHub says the new token is valid and can see the repo.
  def stub_github_valid!
    allow(Lalabase::Github::Client).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:validate_token!).and_return(login: 'gboyke', id: 1)
    allow(github_client).to receive(:fetch_repo_metadata!)
      .and_return(provider_repo_id: 'ext-42', full_name: 'acme/x', default_branch: 'main', private: true)
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  context 'as a chats-write user (admin)' do
    let(:user) { create(:user) }
    let(:role) { create(:admin_role, organisation: organisation) }
    before do
      membership_for(user, role)
      sign_in user
    end

    it 'persists the new token and confirms with a success notice' do
      stub_github_valid!

      patch update_token_path, params: { project_repository: { access_token: new_token } }

      expect(repository.reload.access_token).to eq(new_token) # encrypted column, decrypts on read
      expect(response).to redirect_to(organisation_project_project_repositories_path(organisation, project))
      expect(flash[:notice]).to eq(I18n.t('flash.project_repositories.update_token.success', name: 'acme/x'))
    end

    it 'validates the token against GitHub before saving' do
      stub_github_valid!
      patch update_token_path, params: { project_repository: { access_token: new_token } }
      expect(github_client).to have_received(:validate_token!)
    end

    it 'rejects an invalid token, keeps the old one, and shows an alert' do
      allow(Lalabase::Github::Client).to receive(:new).and_return(github_client)
      allow(github_client).to receive(:validate_token!)
        .and_raise(Lalabase::Github::Client::AuthError, 'Bad credentials')

      patch update_token_path, params: { project_repository: { access_token: 'ghp_still_bad' } }

      expect(repository.reload.access_token).to eq('ghp_old_expired') # unchanged
      expect(flash[:alert]).to be_present
    end
  end

  context 'as a chats-read-only user' do
    let(:user) { create(:user) }
    let(:role) do
      r = create(:role, title: 'Chat Reader', organisation: organisation)
      create(:permission, role: r, category: 'projects', action: 'read_access_chats_all_projects', allowed: true)
      r
    end
    before do
      membership_for(user, role)
      sign_in user
    end

    it 'is denied (token rotation is administrative) and leaves the token unchanged' do
      expect(Lalabase::Github::Client).not_to receive(:new)

      patch update_token_path, params: { project_repository: { access_token: new_token } }

      expect(repository.reload.access_token).to eq('ghp_old_expired')
      expect(response).to have_http_status(:redirect) # Pundit not-authorized
    end
  end

  context 'when the per-org chat beta feature is off (decoupled: rotation stays available)' do
    let(:user) { create(:user) }
    let(:role) { create(:admin_role, organisation: organisation) }
    before do
      membership_for(user, role)
      organisation.update!(code_indexing_enabled: false)
      sign_in user
    end

    # Documentation sync uses the SAME PAT as chat indexing, so rotating an expired
    # token MUST work even for a chat-less org — that recovery path is the whole
    # point of decoupling the repo policy from the chat beta (plan Phase 2).
    it 'still rotates the token with chat off (documentation sync needs a valid PAT)' do
      stub_github_valid!
      patch update_token_path, params: { project_repository: { access_token: new_token } }
      expect(repository.reload.access_token).to eq(new_token)
      expect(response).to redirect_to(organisation_project_project_repositories_path(organisation, project))
      expect(flash[:notice]).to eq(I18n.t('flash.project_repositories.update_token.success', name: 'acme/x'))
    end
  end
end
