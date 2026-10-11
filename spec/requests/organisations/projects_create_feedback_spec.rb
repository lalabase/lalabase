# frozen_string_literal: true

require 'rails_helper'

# Creating a project must give feedback in both directions: a real-world name
# (umlauts, slash) is accepted, and a rejected form comes back as 422 with the
# error message rendered exactly once, the field marked, and the user's choices
# kept. Without the 422, Turbo Drive drops the response and the user sees
# nothing happen after clicking save; the message used to be rendered twice
# (page and form partial); and the re-render used to re-check the
# default-attributes box the user had cleared.
RSpec.describe 'Project creation feedback', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:admin) do
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) { create(:membership, user: user, organisation: organisation, role: admin_role, active: true) }
    user
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in admin
  end

  def create_project(attrs)
    post organisation_projects_path(organisation), params: { project: attrs, create_default_attributes: '0' }
  end

  # After a request the tenant is gone (acts_as_tenant clears it on completion),
  # so counting sets it again.
  def project_count
    ActsAsTenant.with_tenant(organisation) { Project.count }
  end

  it 'accepts a company name with umlaut and slash' do
    expect { create_project(name: 'Kröger Nutzfahrzeuge / Produktkonfigurator') }
      .to change { project_count }.by(1)

    expect(response).to redirect_to(organisation_projects_path(organisation))
    created = ActsAsTenant.with_tenant(organisation) { Project.order(:created_at).last }
    expect(created.name).to eq('Kröger Nutzfahrzeuge / Produktkonfigurator')
  end

  it 'answers a rejected form with 422, shows the message once and marks the field' do
    expected_message = Project.new(name: '').tap(&:validate).errors.full_messages.first

    expect { create_project(name: '') }.not_to(change { project_count })

    expect(response).to have_http_status(:unprocessable_content)
    # The message is counted, not the alert attribute: the duplicate block this
    # branch removed never carried role="alert", so counting that would stay
    # green with the duplicate back in place.
    expect(response.body.scan(ERB::Util.html_escape(expected_message)).size).to eq(1)
    expect(response.body).to include('role="alert"')
    name_field = response.body[/<input[^>]*name="project\[name\]"[^>]*>/]
    expect(name_field).to include('aria-invalid="true"')
  end

  it 'keeps the default-attributes box cleared on the 422 re-render' do
    create_project(name: '')

    checkbox = response.body[/<input[^>]*type="checkbox"[^>]*name="create_default_attributes"[^>]*>/]
    expect(checkbox).to be_present
    expect(checkbox).not_to include('checked')
  end

  it 'offers the default-attributes box checked on a fresh form' do
    get new_organisation_project_path(organisation)

    checkbox = response.body[/<input[^>]*type="checkbox"[^>]*name="create_default_attributes"[^>]*>/]
    expect(checkbox).to include('checked="checked"')
  end

  it 'rejects a duplicate name within the organisation with 422' do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Kröger Nutzfahrzeuge') }

    expect { create_project(name: 'Kröger Nutzfahrzeuge') }.not_to(change { project_count })
    expect(response).to have_http_status(:unprocessable_content)
  end
end
