# frozen_string_literal: true

require 'rails_helper'

# PE1 regression guard: the org member list (memberships#index) is scoped for non-admins to
# the people they collaborate with (project colleagues) plus org-wide staff (admins) — never
# the full org roster. Admins keep the full list and the management controls.
RSpec.describe 'Organisations memberships index scoping', type: :request do
  let(:organisation) { create(:organisation) }
  let(:standard_role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end
  let(:admin_role) { create(:admin_role, organisation: organisation) }

  def member_in(role = standard_role)
    u = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: u, organisation: organisation, role: role, active: true)
    end
    u
  end

  let(:project_a) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:project_b) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  let(:viewer) { member_in }     # external single-project user
  let(:colleague) { member_in }  # shares project_a with viewer
  let(:foreigner) { member_in }  # only on project_b
  let(:admin) { member_in(admin_role) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:project_permission, user: viewer, project: project_a, tickets_access: 'read_only')
    create(:project_permission, user: colleague, project: project_a, tickets_access: 'read_only')
    create(:project_permission, user: foreigner, project: project_b, tickets_access: 'read_only')
    admin # ensure the admin membership exists before the request renders
  end

  after { ActsAsTenant.current_tenant = nil }

  it 'shows a non-admin their collaborators and the admin, but not foreign-project members' do
    sign_in viewer

    get organisation_memberships_path(organisation)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(colleague.email)
    expect(response.body).to include(admin.email) # admin stays contactable
    expect(response.body).not_to include(foreigner.email)
  end

  it 'renders uploaded avatars inside the member circles (S2; preloaded, Prosopite is armed)' do
    # Setup is per-record work (avatar validation + variant pre-warm enqueue
    # fire once per saved member) — pause detection here and measure only the
    # request below, which is where a missing preload would N+1.
    Prosopite.pause
    [colleague, admin].each do |member|
      member.avatar.attach(
        io: Rails.root.join('spec/fixtures/files/test_avatar.png').open,
        filename: 'avatar.png', content_type: 'image/png'
      )
      member.save!
    end
    sign_in viewer
    Prosopite.resume

    get organisation_memberships_path(organisation)

    expect(response).to have_http_status(:ok)
    expect(response.body.scan(%r{rails/active_storage}).size).to be >= 2
  end

  it 'does not show the invite control to a non-admin' do
    sign_in viewer

    get organisation_memberships_path(organisation)

    expect(response.body).not_to include('Neues Mitglied einladen')
  end

  it 'shows the full roster to an admin' do
    sign_in admin

    get organisation_memberships_path(organisation)

    expect(response.body).to include(colleague.email)
    expect(response.body).to include(foreigner.email)
  end
end
