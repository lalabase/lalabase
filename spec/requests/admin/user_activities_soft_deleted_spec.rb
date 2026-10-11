# frozen_string_literal: true

require 'rails_helper'

# Request spec for the admin "user activities" views reached from a user detail
# page ("show all activities" link) and the system-wide activities filter.
#
# Regression guard for the same soft-delete blank-page bug fixed in
# Admin::UsersController#show: these actions loaded the user via plain
# `::User.find`, which the SoftDeletable default scope turns into a 404 for
# soft-deleted (anonymized) users, while set_user's Admin::User lookup resolves
# them. The fix aligns both on `::User.find_with_deleted`.
RSpec.describe 'Admin::UserActivities (soft-deleted users)', type: :request do
  let(:admin_beuser) { create(:beuser) }

  before do
    post admin_log_in_path, params: { email: admin_beuser.email, password: admin_beuser.password }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  it 'renders the per-user activity page for a soft-deleted user' do
    user = create(:user)
    org = create(:organisation)
    ActsAsTenant.with_tenant(org) do
      create(:user_activity, :login, user: user, organisation: org, created_at: 1.hour.ago)
    end
    user.update_columns(deleted_at: Time.current)

    get admin_user_user_activities_path(user)

    expect(response).to have_http_status(:ok)
  end

  it 'renders the activities index filtered by a soft-deleted user' do
    user = create(:user)
    user.update_columns(deleted_at: Time.current)

    get admin_user_activities_path(user_id: user.id)

    expect(response).to have_http_status(:ok)
  end

  # Not about soft-deleted users, but the same admin controller and session: the
  # export writes the organisation name, which any registrant chooses.
  it 'exports a formula-like organisation name as text' do
    user = create(:user)
    org = create(:organisation, name: '=1+1')
    ActsAsTenant.with_tenant(org) do
      create(:user_activity, :login, user: user, organisation: org)
    end

    post export_admin_user_activities_path(format: :csv)

    names = CSV.parse(response.body, headers: true).map { |row| row['Organisation'] }
    expect(names).to eq(["'=1+1"])
  end
end
