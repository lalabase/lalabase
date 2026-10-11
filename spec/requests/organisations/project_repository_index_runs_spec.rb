# frozen_string_literal: true

require 'rails_helper'

# Covers the index-run history view (the "Index-Verlauf" link from the repo
# management page): renders the history for repo-read users. Since the repo policy
# was decoupled from the chat beta (plan Phase 2), this is reachable via chats:read
# OR documentation:write and NO LONGER requires the chat feature to be enabled.
RSpec.describe 'Project repository index runs', type: :request do
  let(:organisation) { create(:organisation, code_indexing_enabled: true) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:repository) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_repository, project: project, organisation: organisation, full_name: 'acme/x')
    end
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
  end

  def runs_path
    index_runs_organisation_project_project_repository_path(organisation, project, repository)
  end

  it 'renders the run history and shows the short commit SHA' do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_index_run, project_repository: repository, organisation: organisation,
                                 trigger: 'initial', status: 'ready', commit_sha: 'abc123def456789')
    end

    get runs_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('abc123de') # short SHA (first 8)
  end

  it 'renders a failed run with its badge and the error message, HTML-escaped' do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_index_run, project_repository: repository, organisation: organisation,
                                 trigger: 'push', status: 'failed', incremental: true,
                                 error_message: '<script>alert(1)</script> clone failed')
    end

    get runs_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t('views.organisations.indexing.runs.status.failed'))
    # error_message is free text from git/provider stderr → the cell uses <%= %>, so
    # it must be HTML-escaped, never rendered raw. Pins the escaping (raw → XSS).
    expect(response.body).not_to include('<script>alert(1)</script>')
    expect(response.body).to include('clone failed')
  end

  it 'renders an incremental run with the incremental scope summary (not the full one)' do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_index_run, project_repository: repository, organisation: organisation,
                                 trigger: 'push', status: 'ready', incremental: true,
                                 files_count: 3, symbols_added: 5, symbols_removed: 2)
    end

    get runs_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(
      I18n.t('views.organisations.indexing.runs.scope.incremental', files: 3, added: 5, removed: 2)
    )
  end

  it 'renders an empty state when there are no runs' do
    get runs_path
    expect(response).to have_http_status(:ok)
  end

  it 'caps the run list at RECENT_RUNS_LIMIT, dropping the oldest (newest first)' do
    stub_const('Organisations::ProjectRepositoriesController::RECENT_RUNS_LIMIT', 2)
    ActsAsTenant.with_tenant(organisation) do
      create(:project_index_run, project_repository: repository, organisation: organisation,
                                 commit_sha: 'old00000aa', created_at: 3.hours.ago)
      create(:project_index_run, project_repository: repository, organisation: organisation,
                                 commit_sha: 'mid00000bb', created_at: 2.hours.ago)
      create(:project_index_run, project_repository: repository, organisation: organisation,
                                 commit_sha: 'new00000cc', created_at: 1.hour.ago)
    end

    get runs_path

    expect(response.body).to include('new00000') # two newest shown
    expect(response.body).to include('mid00000')
    expect(response.body).not_to include('old00000') # oldest dropped by the limit
  end

  it 'stays reachable with the chat feature off (repo policy decoupled from the chat beta)' do
    organisation.update!(code_indexing_enabled: false)
    get runs_path
    expect(response).to have_http_status(:ok) # show? no longer requires chat; the admin is authorized
  end
end
