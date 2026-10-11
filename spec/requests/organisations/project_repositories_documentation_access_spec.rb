# frozen_string_literal: true

require 'rails_helper'

# Connected-functional-block coverage for the repo-policy decouple (plan Phase 2).
#
# The unit policy specs prove ProjectRepositoryPolicy in isolation, but the repo
# page is reached through a STACK of authorisation layers the unit specs don't
# exercise together:
#   set_project          → authorize @project, :show?      (ProjectPolicy)
#   index                → policy_scope(ProjectRepository) (ProjectRepositoryPolicy::Scope)
#   create/destroy/…     → authorize @repository, :<action>? (ProjectRepositoryPolicy)
#   index render         → ConnectComponent (real can_manage? + indexing_ui_enabled?)
#
# This spec drives the DECOUPLE'S TARGET PERSONA end-to-end: a documentation:write
# user (NOT an admin, NOT a chat user) in a CHAT-LESS org — the exact person the
# feature exists for (connect a repo for doc sync, rotate an expired PAT without
# settings access). It is the integration counterpart to the isolated policy matrix.
RSpec.describe 'Project repositories — documentation-manager access (decoupled)', type: :request do
  include ActiveJob::TestHelper

  let(:organisation) { create(:organisation, code_indexing_enabled: false) } # chat OFF on purpose
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  # Persona: a NON-admin, NON-chat user whose ONLY grant is project-level
  # documentation read_write. This is the realistic "documentation manager".
  let(:doc_manager_role) { create(:role, title: 'Member', organisation: organisation, is_default: true) }
  let(:doc_manager) do
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: doc_manager_role, active: true)
      ProjectPermission.create!(user: user, project: project, documentation_access: 'read_write')
    end
    user
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def index_path = organisation_project_project_repositories_path(organisation, project)

  def stub_github_valid!
    client = instance_double(Lalabase::Github::Client)
    allow(client).to receive(:validate_token!).and_return(login: 'gboyke', id: 1)
    allow(client).to receive(:fetch_repo_metadata!)
      .and_return(provider_repo_id: 'ext-99', full_name: 'acme/docs-repo', default_branch: 'main', private: true)
    allow(Lalabase::Github::Client).to receive(:new).and_return(client)
    client
  end

  describe 'GET #index (the whole authorisation stack + real component render)' do
    let!(:repo) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project_repository, project: project, organisation: organisation, full_name: 'acme/docs-repo')
      end
    end

    before { sign_in doc_manager }

    it 'lets the documentation manager reach the page (set_project + scope both pass)' do
      get index_path
      expect(response).to have_http_status(:ok)
    end

    it 'renders the connected repo and the connect form (management is allowed)' do
      get index_path
      expect(response.body).to include('acme/docs-repo')
      expect(response.body).to include('project_repository[full_name]')
    end

    it 'still offers token rotation (doc sync needs an unexpired PAT — NOT chat-gated)' do
      get index_path
      expect(response.body).to include(I18n.t('views.organisations.indexing.token_update.title'))
    end

    it 'hides the chat-only webhook/index UI (chat-less org — real component, not stubbed)' do
      get index_path
      expect(response.body).not_to include(I18n.t('views.organisations.indexing.webhook.title'))
      expect(response.body).not_to include(I18n.t('views.organisations.indexing.runs.link'))
    end
  end

  describe 'POST #create (the ORIGIN bug: a doc manager can actually connect a repo)' do
    before { sign_in doc_manager }

    it 'connects the repository purely via documentation rights, chat off' do
      stub_github_valid!
      post index_path, params: { project_repository: { full_name: 'acme/docs-repo', access_token: 'ghp_valid' } }
      expect(response).to redirect_to(index_path)
      # Count OUTSIDE the request (tenant already reset) must be re-scoped, else
      # require_tenant raises NoTenantSet on the bare ProjectRepository query.
      created = ActsAsTenant.with_tenant(organisation) do
        ProjectRepository.where(project: project, full_name: 'acme/docs-repo').exists?
      end
      expect(created).to be(true)
    end
  end

  describe 'PATCH #update_token (AK 7: PAT rotation without settings access)' do
    let!(:repo) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project_repository, project: project, organisation: organisation,
                                    full_name: 'acme/docs-repo', access_token: 'ghp_old')
      end
    end

    before { sign_in doc_manager }

    it 'rotates the token via documentation rights, chat off' do
      stub_github_valid!
      patch update_token_organisation_project_project_repository_path(organisation, project, repo),
            params: { project_repository: { access_token: 'ghp_new_valid' } }
      expect(repo.reload.access_token).to eq('ghp_new_valid')
      expect(response).to redirect_to(index_path)
    end
  end

  describe 'negative: a documentation READ-only user is denied (least-privilege end-to-end)' do
    let(:doc_reader) do
      user = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, role: doc_manager_role, active: true)
        ProjectPermission.create!(user: user, project: project, documentation_access: 'read_only')
      end
      user
    end

    before { sign_in doc_reader }

    it 'cannot connect a repo (create? denied for documentation:read)' do
      stub_github_valid!
      post index_path, params: { project_repository: { full_name: 'acme/docs-repo', access_token: 'ghp_valid' } }
      expect(response).to be_redirect
      expect(flash[:alert]).to be_present
      persisted = ActsAsTenant.with_tenant(organisation) do
        ProjectRepository.where(project: project).exists?
      end
      expect(persisted).to be(false)
    end
  end

  # The decouple gap (found in deep review): a GLOBAL documentation:write role WITHOUT
  # a project-permission row and WITHOUT an explicit read grant. ProjectPolicy#show?
  # (has_global_read_permission?) only honours literal read_access_* actions — it
  # ignores write-implies-read — so set_project used to LOCK this manager out of their
  # own repo page even though the decoupled ProjectRepositoryPolicy allows them. The
  # fix gates set_project through the repo policy. These are the regression guards.
  describe 'GLOBAL documentation:write role (no project-permission row)' do
    let(:global_doc_writer_role) do
      role = create(:role, title: 'Doc Writer (global)', organisation: organisation)
      create(:permission, role: role, category: 'projects',
                          action: 'write_access_documentation_all_projects', allowed: true)
      role
    end
    let(:global_doc_writer) do
      user = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, role: global_doc_writer_role, active: true)
      end
      user
    end

    before { sign_in global_doc_writer }

    it 'can reach the repo page (set_project gates via the repo policy, not ProjectPolicy#show?)' do
      ActsAsTenant.with_tenant(organisation) do
        create(:project_repository, project: project, organisation: organisation, full_name: 'acme/docs-repo')
      end
      get index_path
      expect(response).to have_http_status(:ok)
    end

    it 'can connect a repo end-to-end (chat off, global documentation rights only)' do
      stub_github_valid!
      post index_path, params: { project_repository: { full_name: 'acme/docs-repo', access_token: 'ghp_valid' } }
      expect(response).to redirect_to(index_path)
      created = ActsAsTenant.with_tenant(organisation) do
        ProjectRepository.where(project: project, full_name: 'acme/docs-repo').exists?
      end
      expect(created).to be(true)
    end
  end

  # The flip side of the fix: gating set_project on the REPO read audience
  # (chats:read OR documentation:write) also NARROWS it. A user whose only project
  # access is a non-repo area (tickets) previously reached an empty repo page via the
  # broader ProjectPolicy#show?; now they are redirected — consistent with the
  # policy_scope (which already showed them nothing) and closes a page-existence leak.
  describe 'tightening: a non-repo-area reader (tickets only) is kept off the repo page' do
    let(:tickets_reader_role) do
      role = create(:role, title: 'Tickets Reader', organisation: organisation)
      create(:permission, role: role, category: 'projects',
                          action: 'read_access_tickets_all_projects', allowed: true)
      role
    end
    let(:tickets_reader) do
      user = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, role: tickets_reader_role, active: true)
      end
      user
    end

    before { sign_in tickets_reader }

    it 'is redirected from the repo index (no repo-area access)' do
      get index_path
      expect(response).to be_redirect
    end
  end

  # Read-only hardening (Phase 1, plan 1e) through the REAL policy + real component
  # render: ProjectRepositoryPolicy#index? needs only chats:read, so such a visitor
  # reaches the page by URL. Every WRITE affordance must be hidden — otherwise it
  # 403s on submit. The component specs stub the predicates; this exercises the
  # actual ProjectRepositoryPolicy#create? end-to-end (the gap the stubbed specs left).
  describe 'read-only visitor (chats:read) sees no write affordances (1e)' do
    let(:chats_reader) do
      user = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, role: doc_manager_role, active: true)
        ProjectPermission.create!(user: user, project: project, chats_access: 'read_only')
      end
      user
    end

    let!(:repo) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project_repository, project: project, organisation: organisation, full_name: 'acme/docs-repo')
      end
    end

    before { sign_in chats_reader }

    it 'reaches the page (index? via chats:read) but sees neither the connect form nor disconnect' do
      get index_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('acme/docs-repo') # the read-only list still renders
      expect(response.body).not_to include('project_repository[full_name]')
      expect(response.body).not_to include('project_repository[access_token]')
      expect(response.body).not_to include(I18n.t('views.organisations.project_repositories.index.disconnect'))
    end
  end
end
