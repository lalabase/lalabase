# frozen_string_literal: true

require 'rails_helper'

# Round-trip coverage (plan 1d): a user who reaches the repo page FROM the
# documentation flow (origin=documentation) must be sent back there after a
# successful connect — and the marker must survive the UNhappy path (a failed
# GitHub validation re-renders the form), because a PAT typo is the likely case,
# not the edge case. Also covers the enum sanitising (no open-redirect surface)
# and the contextual back link.
#
# Driven as an org admin: origin handling is orthogonal to which right grants
# access, so the simplest authorised persona keeps the focus on the round-trip.
RSpec.describe 'Project repositories — documentation round-trip (origin)', type: :request do
  let(:organisation) { create(:organisation, code_indexing_enabled: true) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:admin) do
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
    user
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def index_path(**opts) = organisation_project_project_repositories_path(organisation, project, **opts)
  def new_set_path = new_organisation_project_documentation_set_path(organisation, project)
  def edit_path = edit_organisation_project_path(organisation, project)
  def doc_index_path = organisation_project_documentation_index_path(organisation, project)

  # Two-call GitHub happy path (validate_token! + fetch_repo_metadata!).
  def stub_github_valid!
    client = instance_double(Lalabase::Github::Client)
    allow(client).to receive(:validate_token!).and_return(login: 'gboyke', id: 1)
    allow(client).to receive(:fetch_repo_metadata!)
      .and_return(provider_repo_id: 'ext-1', full_name: 'acme/backend', default_branch: 'main', private: true)
    allow(Lalabase::Github::Client).to receive(:new).and_return(client)
  end

  # validate_token! raises the AuthError the controller maps to a form error →
  # render :new (the unhappy path that must preserve origin).
  def stub_github_invalid!
    client = instance_double(Lalabase::Github::Client)
    allow(client).to receive(:validate_token!).and_raise(Lalabase::Github::Client::AuthError)
    allow(Lalabase::Github::Client).to receive(:new).and_return(client)
  end

  before { sign_in admin }

  describe 'GET #index — back link + origin propagation into the form' do
    it 'shows a "Documentation" back link to the documentation area when origin=documentation' do
      get index_path(origin: 'documentation')
      expect(response.body).to include(I18n.t('views.organisations.project_repositories.index.back_documentation'))
      expect(response.body).to include(doc_index_path)
    end

    it 'shows a "Settings" back link to project settings by default (no origin)' do
      get index_path
      expect(response.body).to include(I18n.t('views.organisations.project_repositories.index.back_settings'))
      expect(response.body).to include(edit_path)
    end

    it 'carries origin into the connect form as a hidden field' do
      get index_path(origin: 'documentation')
      expect(response.body).to include('name="origin"')
      expect(response.body).to match(/name="origin"[^>]*value="documentation"/)
    end

    it 'emits NO origin hidden field for the plain settings entry' do
      get index_path
      expect(response.body).not_to include('name="origin"')
    end

    # Real allowlist guard (the POST-redirect test below is vacuous on its own: ANY
    # non-documentation value already redirects to the repo page). An unknown origin
    # must collapse to nil so the raw value never rides into the connect form. Kills
    # the mutation `sanitized_origin -> params[:origin]` (drop the allowlist): that
    # would make @origin truthy and render the hidden field. (back-link text is not
    # asserted here — "Dokumentation"/"Einstellungen" also appear in the nav.)
    it 'does not reflect an UNKNOWN origin into the form (allowlist collapses it to nil)' do
      get index_path(origin: 'https://evil.example')
      expect(response.body).not_to include('name="origin"')
    end
  end

  describe 'POST #create — origin decides the post-connect destination' do
    it 'redirects back into documentation set-creation when origin=documentation' do
      stub_github_valid!
      post index_path, params: { origin: 'documentation',
                                 project_repository: { full_name: 'acme/backend', access_token: 'ghp_ok' } }
      expect(response).to redirect_to(new_set_path)
    end

    it 'redirects to the repo page (unchanged behaviour) when no origin is given' do
      stub_github_valid!
      post index_path, params: { project_repository: { full_name: 'acme/backend', access_token: 'ghp_ok' } }
      expect(response).to redirect_to(index_path)
    end

    it 'ignores an UNKNOWN origin (enum allowlist → no open redirect)' do
      stub_github_valid!
      post index_path, params: { origin: 'https://evil.example',
                                 project_repository: { full_name: 'acme/backend', access_token: 'ghp_ok' } }
      expect(response).to redirect_to(index_path)
    end
  end

  describe 'UNhappy path — origin survives a failed connect (the likely case)' do
    it 'keeps the origin hidden field when GitHub validation fails (render :new)' do
      stub_github_invalid!
      post index_path, params: { origin: 'documentation',
                                 project_repository: { full_name: 'acme/backend', access_token: 'ghp_bad' } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to match(/name="origin"[^>]*value="documentation"/)
    end

    it 'still round-trips to documentation on the retry after a first failure' do
      stub_github_invalid!
      post index_path, params: { origin: 'documentation',
                                 project_repository: { full_name: 'acme/backend', access_token: 'ghp_bad' } }
      # Second attempt with a good token — the form resubmitted origin from its
      # hidden field, so the redirect still goes back to documentation.
      stub_github_valid!
      post index_path, params: { origin: 'documentation',
                                 project_repository: { full_name: 'acme/backend', access_token: 'ghp_ok' } }
      expect(response).to redirect_to(new_set_path)
    end
  end
end
