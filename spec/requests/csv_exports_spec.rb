# frozen_string_literal: true

require 'rails_helper'

# Exercise the lazy-loaded controllers and consume the streamed response. Ruby
# 3.4 no longer makes CSV available under Bundler without an explicit dependency.
RSpec.describe 'CSV export runtime dependencies', type: :request do
  let(:organisation) { create(:organisation, name: 'CSV Export Organisation') }
  let(:user) { create(:user) }

  def sign_in_admin
    admin = create(:beuser)
    post admin_log_in_path, params: { email: admin.email, password: admin.password }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  it 'streams an email log as a CSV attachment' do
    email_log = ActsAsTenant.with_tenant(organisation) do
      create(:email_log, organisation: organisation, subject: 'CSV export regression')
    end
    sign_in_admin

    get export_admin_email_logs_path(format: :csv)

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('text/csv')
    expect(response.headers['Content-Disposition']).to include('attachment')
    row = CSV.parse(response.body, headers: true).find { |entry| entry['ID'] == email_log.id }
    expect(row.to_h).to include('Organisation' => organisation.name, 'Subject' => email_log.subject)
  end

  it 'exports a user activity as a CSV attachment' do
    activity = ActsAsTenant.with_tenant(organisation) do
      create(:user_activity, :login, user: user, organisation: organisation)
    end
    sign_in_admin

    post export_admin_user_activities_path(format: :csv), params: { user_id: user.id }

    expect(response).to have_http_status(:ok)
    expect(response.headers['Content-Disposition']).to include('attachment')
    row = CSV.parse(response.body, headers: true).find { |entry| entry['ID'] == activity.id }
    expect(row.to_h).to include('User' => user.email, 'Organisation' => organisation.name)
  end

  it 'exports a customer description with the Excel-compatible CSV encoding' do
    group = ActsAsTenant.with_tenant(organisation) do
      role = create(:admin_role, organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      project = create(:project, organisation: organisation)
      group = create(:time_session_group, organisation: organisation, creator: user)
      create(:time_session, organisation: organisation, project: project, creator: user,
                            time_session_group: group, customer_description: 'Customer export regression')
      group
    end
    sign_in user

    get export_customer_descriptions_organisation_time_session_group_path(organisation, group)

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('text/csv')
    expect(response.headers['Content-Disposition']).to include('attachment')
    expect(response.body).to start_with("\xEF\xBB\xBF")
    rows = CSV.parse(response.body.delete_prefix("\xEF\xBB\xBF"), col_sep: ';', headers: true)
    expect(rows.length).to eq(1)
    expect(rows.first.fields).to include('Customer export regression')
  end
end
