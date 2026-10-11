# frozen_string_literal: true

require 'rails_helper'

# Request spec for the admin user detail view (Admin::UsersController#show).
#
# Regression guard for the "detail view shows nothing" bug: the admin index and
# the deleted-users list link to soft-deleted (anonymized) users, but #show
# loaded activities via plain `::User.find`, which the SoftDeletable default
# scope (`WHERE deleted_at IS NULL`) turned into a RecordNotFound -> blank 404.
# Admin::User (used for the primary lookup) has no such scope, so the two lookups
# disagreed. The fix aligns them via `::User.find_with_deleted`.
RSpec.describe 'Admin::Users#show', type: :request do
  let(:admin_beuser) { create(:beuser) }

  def log_in_admin
    post admin_log_in_path, params: { email: admin_beuser.email, password: admin_beuser.password }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  before { log_in_admin }

  it 'renders the detail page for an active user' do
    user = create(:user)

    get admin_user_path(user)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(user.email)
  end

  # The core regression: before the fix this returned 404 (blank page) because
  # ::User.find applied the soft-delete default scope while Admin::User did not.
  it 'renders the detail page for a soft-deleted user instead of 404ing' do
    user = create(:user)
    user.update_columns(deleted_at: Time.current, deletion_recommended: true)

    get admin_user_path(user)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(user.reload.email)
  end

  # The billing accounts section of this page belongs to the operator console
  # (slot :user_sections); its examples live in the engine's
  # spec/requests/admin/operator_extensions_spec.rb, and
  # without_operator_extensions_spec.rb pins the page without it.

  it 'renders the activity history for a soft-deleted user with prior login activity' do
    user = create(:user)
    org = create(:organisation)
    ActsAsTenant.with_tenant(org) do
      create(:user_activity, :login, :with_request_info, user: user, organisation: org, created_at: 1.hour.ago)
    end
    user.update_columns(deleted_at: Time.current)

    get admin_user_path(user)

    expect(response).to have_http_status(:ok)
  end

  # The project permissions section. Every example above creates a user WITHOUT
  # a ProjectPermission, so the view only ever rendered the empty-state branch
  # and the loop over the permissions (show.html.erb) was never executed by any
  # spec. That blind spot let a real 500 reach production: Admin::ProjectPermission
  # kept its own hand-written area list, `meetings` (#219) and `processes` (#374)
  # were added to ProjectPermission only, and the view's call to the dynamically
  # generated `meetings_access_text` raised NoMethodError for every user who had
  # at least one permission row.
  describe 'project permissions section' do
    def create_permission(user, levels = {})
      organisation = create(:organisation)
      project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      Admin::ProjectPermission.create!({ user_id: user.id, project_id: project.id }.merge(levels))
      project
    end

    it 'renders the page for a user who has a project permission' do
      user = create(:user)
      project = create_permission(user)

      get admin_user_path(user)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(project.name)
    end

    # Pins the section against the areas the tenant-side model defines, so an
    # area added there but not rendered here fails loudly instead of 500ing.
    it 'lists every access area of ProjectPermission with its level' do
      user = create(:user)
      create_permission(user, meetings_access: 'read_write', documentation_access: 'read_only')

      get admin_user_path(user)

      ProjectPermission.access_areas.each do |area|
        expect(response.body).to include(I18n.t("views.organisations.project_permissions.areas.#{area}"))
      end
      expect(response.body).to include(I18n.t('views.organisations.project_permissions.levels.read_write'))
      expect(response.body).to include(I18n.t('views.organisations.project_permissions.levels.read_only'))
    end
  end
end
