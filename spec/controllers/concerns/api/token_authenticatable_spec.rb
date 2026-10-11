# frozen_string_literal: true

require 'rails_helper'

# Unit tests for the with_*_scope helpers. Anonymous controller approach so the
# helpers can be exercised against real ActsAsTenant + token state.
RSpec.describe Api::TokenAuthenticatable, :ci_guard, type: :controller do
  controller(Api::V1::BaseController) do
    # Api::V1::BaseController arms a Pundit tripwire (after_action :verify_authorized) so a real
    # endpoint that forgets to authorize fails loudly. This anonymous controller exists only to
    # exercise the with_*_scope helpers against real ActsAsTenant state and deliberately calls no
    # authorize — without the skip, the tripwire raises AuthorizationNotPerformedError on every
    # happy path before the assertions run. The tripwire itself is covered by the request specs
    # of the concrete Api::V1 controllers.
    skip_after_action :verify_authorized

    def show
      org = Organisation.find(params[:org_id])
      with_organisation_scope(org) do
        render json: { tenant: ActsAsTenant.current_tenant&.id }
      end
    end

    def project_check
      project = Project.unscoped.find(params[:project_id])
      with_project_scope(project) do
        render json: { tenant: ActsAsTenant.current_tenant&.id }
      end
    end
  end

  before do
    routes.draw do
      get '/show' => 'api/v1/base#show'
      get '/project_check' => 'api/v1/base#project_check'
    end
  end

  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  let(:pat) do
    pat = build(:personal_access_token, user: user, organisations: [organisation])
    pat.token_hash = nil
    pat.token_prefix = nil
    pat.generate_token!
    pat
  end

  before do
    request.headers['Authorization'] = "Bearer #{pat.token}"
  end

  describe '#with_organisation_scope' do
    it 'sets ActsAsTenant.current_tenant inside the block when the org is in scope' do
      get :show, params: { org_id: organisation.id }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['tenant']).to eq(organisation.id)
    end

    it 'raises 404 (not 403) for an org outside the token scope' do
      get :show, params: { org_id: other_organisation.id }
      expect(response).to have_http_status(:not_found)
    end

    # The token was made while the owner belonged to the organisation; a
    # deactivated membership must take the organisation out of its reach.
    it 'raises 404 once the owner\'s membership is inactive' do
      membership.update!(active: false)

      get :show, params: { org_id: organisation.id }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe '#with_project_scope' do
    let(:project) do
      ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    end
    let(:foreign_project) do
      ActsAsTenant.with_tenant(other_organisation) { create(:project, organisation: other_organisation) }
    end

    it 'sets the tenant from the project organisation' do
      get :project_check, params: { project_id: project.id }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['tenant']).to eq(organisation.id)
    end

    it 'raises 404 for a project in an org outside the token scope' do
      get :project_check, params: { project_id: foreign_project.id }
      expect(response).to have_http_status(:not_found)
    end

    it 'raises 404 for a project once the owner\'s membership is inactive' do
      membership.update!(active: false)

      get :project_check, params: { project_id: project.id }
      expect(response).to have_http_status(:not_found)
    end

    context 'with restricted project scope (all_projects=false)' do
      let(:other_project) do
        ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      end

      let(:restricted_pat) do
        pat = build(:personal_access_token, user: user)
        pat.personal_access_token_organisations.build(organisation: organisation, all_projects: false)
        pat.personal_access_token_projects.build(project: project)
        pat.assign_token!
        pat.save!
        pat
      end

      before do
        request.headers['Authorization'] = "Bearer #{restricted_pat.token}"
      end

      it 'allows the explicitly scoped project' do
        get :project_check, params: { project_id: project.id }
        expect(response).to have_http_status(:ok)
      end

      it 'denies other projects in the same org' do
        get :project_check, params: { project_id: other_project.id }
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
