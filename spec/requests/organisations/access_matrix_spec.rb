# frozen_string_literal: true

require 'rails_helper'

# Authorization contract for the org-wide access matrix. The matrix is admin-only, and a
# non-admin is redirected with a flash — NOT served a 403 (decision C1: follow the app-wide
# Pundit deny pattern, application_controller#user_not_authorized).
RSpec.describe 'Organisations::AccessMatrix', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role)  { create(:admin_role, organisation: organisation) }
  let(:member_role) { create(:role, organisation: organisation, title: 'member') }

  let(:admin)  { create(:user) }
  let(:member) { create(:user) }

  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def matrix_path
    organisation_access_matrix_index_path(organisation)
  end

  context 'as an account admin' do
    before { sign_in admin }

    it 'renders the matrix (200)' do
      get matrix_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('views.organisations.access_matrix.index.title'))
    end

    it 'renders the populated grid — project column + member row + a pill' do
      project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Apollo') }
      member = create(:user, first_name: 'Rio', last_name: 'Tester')
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: member, organisation: organisation, role: member_role, active: true)
        create(:project_permission, user: member, project: project, tickets_access: 'read_write')
      end

      get matrix_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Apollo')      # project column header
      expect(response.body).to include('Rio Tester')  # member row header
      expect(response.body).to include('am-cell-td') # a rendered cell
    end

    it 'never renders another organisation\'s projects or members (tenant isolation)' do
      other_org = create(:organisation)
      ActsAsTenant.with_tenant(other_org) do
        create(:project, organisation: other_org, name: 'ForeignProject')
        other_role = create(:admin_role, organisation: other_org)
        other_user = create(:user, first_name: 'Foreign', last_name: 'Person')
        create(:membership, user: other_user, organisation: other_org, role: other_role, active: true)
      end

      get matrix_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('ForeignProject')
      expect(response.body).not_to include('Foreign Person')
    end
  end

  context 'as a non-admin member — even one holding manage_users' do
    let!(:member_membership) do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: member, organisation: organisation, role: member_role, active: true)
      end
    end

    before do
      create(:permission, role: member_role, category: 'accounts', action: 'manage_users', allowed: true)
      sign_in member
    end

    it 'redirects with a flash instead of returning 403 (decision C1)' do
      get matrix_path

      expect(response).to have_http_status(:found)
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to be_present
    end
  end

  context 'when not signed in' do
    it 'redirects to the login' do
      get matrix_path

      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
