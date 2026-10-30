# frozen_string_literal: true

require 'rails_helper'

# A member chooses which email the others see (User::EmailDisplay): the login
# address, a contact address, or none. Every page inside an organisation that
# shows or searches a member's email follows that choice, also for an
# organisation admin. Each check proves the page rendered (a positive anchor)
# before it claims that the login address is absent.
RSpec.describe 'The email a member shows to others', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:account_admin_role) do
    ActsAsTenant.with_tenant(organisation) { create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE) }
  end

  def member(first_name, email, **choice)
    user = create(:user, first_name: first_name, last_name: 'Beispiel', email: email, **choice)
    create(:membership, user: user, organisation: organisation, role: account_admin_role, active: true)
    user
  end

  let!(:admin) { member('Adele', 'adele@example.com') }
  let!(:lena) { member('Lena', 'lena-login@example.com', email_visibility: 'contact', contact_email: 'lena.team@example.com') }
  let!(:nina) { member('Nina', 'nina-login@example.com', email_visibility: 'none') }

  before { sign_in admin }

  def expect_no_hidden_login_address(body)
    expect(body).not_to include('lena-login')
    expect(body).not_to include('nina-login')
  end

  describe 'the people page' do
    it 'lists a member with the chosen email, and nothing for one who shows none' do
      get organisation_people_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Lena', 'Nina', 'lena.team@example.com')
      expect_no_hidden_login_address(response.body)
    end

    it 'links the chosen email in the lane of a member' do
      get organisation_people_path(organisation, member_id: lena.id),
          headers: { 'Turbo-Frame' => Organisations::PeopleController::DETAIL_FRAME_ID }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('mailto:lena.team@example.com')
      expect_no_hidden_login_address(response.body)
    end

    it 'shows no email in the lane of a member who shows none' do
      get organisation_people_path(organisation, member_id: nina.id),
          headers: { 'Turbo-Frame' => Organisations::PeopleController::DETAIL_FRAME_ID }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Nina')
      expect(response.body).not_to include('mailto:')
      expect_no_hidden_login_address(response.body)
    end

    it 'finds a member by the shown email, never by a hidden login address' do
      get organisation_people_path(organisation, q: 'lena.team')
      expect(response.body).to include('lena.team@example.com')

      get organisation_people_path(organisation, q: 'lena-login')
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('lena.team@example.com')

      get organisation_people_path(organisation, q: 'nina-login')
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('Nina Beispiel')
    end
  end

  describe 'the members page' do
    it 'shows the chosen email in the rows, to an admin too' do
      get organisation_memberships_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Lena', 'Nina', 'lena.team@example.com', 'adele@example.com')
      expect_no_hidden_login_address(response.body)
    end

    it 'shows the chosen email in the side panel of a member' do
      membership = Membership.find_by!(user: lena, organisation: organisation)
      get organisation_memberships_path(organisation, membership_id: membership.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('lena.team@example.com')
      expect_no_hidden_login_address(response.body)
    end

    # Ties in the name break on the SHOWN email: the order must not leak the
    # alphabetical position of a hidden login address.
    it 'sorts two members of the same name by the shown email, not the login address' do
      member('Max', 'a-login@example.com', email_visibility: 'contact', contact_email: 'z-team@example.com')
      member('Max', 'z-login@example.com', email_visibility: 'contact', contact_email: 'a-team@example.com')

      get organisation_memberships_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(response.body.index('a-team@example.com')).to be < response.body.index('z-team@example.com')
      expect(response.body).not_to include('a-login@example.com', 'z-login@example.com')
    end

    it 'finds a member by the shown email, never by a hidden login address' do
      get organisation_memberships_path(organisation, q: 'lena.team')
      expect(response.body).to include('lena.team@example.com')

      get organisation_memberships_path(organisation, q: 'lena-login')
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('lena.team@example.com')
    end
  end

  describe 'the person form of a member' do
    it 'shows the chosen email in the locked field, and nothing for one who shows none' do
      lena_row = create(:person, organisation: organisation, user: lena, name: 'Lena Beispiel')
      nina_row = create(:person, organisation: organisation, user: nina, name: 'Nina Beispiel')
      frame = { 'Turbo-Frame' => Organisations::PeopleController::DETAIL_FRAME_ID }

      get edit_organisation_person_path(organisation, lena_row), headers: frame
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('value="lena.team@example.com"')
      expect_no_hidden_login_address(response.body)

      get edit_organisation_person_path(organisation, nina_row), headers: frame
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('person_email_locked')
      expect_no_hidden_login_address(response.body)
    end
  end

  describe 'the activity search of a project' do
    # project.member_added belongs to the members area (Activities::AreaRegistry).
    before { create(:project_permission, user: admin, project: project, tickets_access: 'read_write', members_access: 'read_only') }

    # Rows written before this change still carry the login address in their
    # parameters; the search must not read it there either.
    it 'never confirms a hidden login address, also from an older member_added row' do
      ActsAsTenant.with_tenant(organisation) do
        create(:activity, trackable: project, organisation: organisation, actor: admin, secondary: nina,
                          key: 'project.member_added', action: 'member_added',
                          parameters: { 'user_name' => 'Zugang Nordlicht', 'user_email' => 'nina-login@example.com' })
      end
      path = ->(q) { organisation_project_activities_path(organisation_id: organisation.id, project_id: project.id, q: q) }
      # The row reads "<event>: <member>"; the event label and the member name
      # also stand alone in the page's filters, the pair only in the row.
      row = 'Mitglied hinzugefügt: Nina Beispiel'

      get path.call('Zugang Nord')
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(row)

      get path.call('nina-login@example.com')
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(row)
    end

    it 'never confirms a hidden login address from an older assignee key' do
      ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: 'Kanbanfreigabe') }
      ActsAsTenant.with_tenant(organisation) do
        create(:activity, trackable: ticket, organisation: organisation, actor: admin, secondary: nina,
                          key: 'ticket.assigned', action: 'assigned', parameters: { 'assignee_email' => 'nina-login@example.com' })
      end
      path = ->(q) { organisation_project_activities_path(organisation_id: organisation.id, project_id: project.id, q: q) }

      get path.call('Kanbanfrei')
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Kanbanfreigabe')

      get path.call('nina-login@example.com')
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('Kanbanfreigabe')
    end

    it 'stores no login address when a member joins a project' do
      activity = ActsAsTenant.with_tenant(organisation) do
        Current.set(user: admin) { project.track_member_added(nina) }
        Activity.where(trackable: project, action: 'member_added').order(:created_at).last
      end

      expect(activity.parameters).to include('user_name')
      expect(activity.parameters.to_json).not_to include('nina-login')
    end
  end

  describe 'the codebase import preview' do
    it 'names a same-domain member by name and shown email, never by a hidden login address' do
      organisation.update!(data_import_enabled: true)
      file = ActsAsTenant.with_tenant(organisation) do
        create(:codebase_import_file, :with_valid_users_xml, organisation: organisation, user: admin)
      end

      get preview_import_organisation_codebase_import_file_path(organisation, file)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Lena Beispiel', 'lena.team@example.com')
      expect_no_hidden_login_address(response.body)
    end
  end

  describe 'sharing a smart folder' do
    let(:folder) do
      ActsAsTenant.with_tenant(organisation) do
        create(:smart_folder, user: admin, organisation: organisation, project: project, target_object_type: 'Ticket')
      end
    end

    before do
      [admin, lena, nina].each { |user| create(:project_permission, user: user, project: project, tickets_access: 'read_write') }
    end

    it 'offers the members by name and shown email' do
      get share_organisation_smart_folder_path(organisation, folder)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Lena Beispiel', 'Nina Beispiel')
      expect_no_hidden_login_address(response.body)
    end

    it 'names the members a folder is shared with without a hidden login address' do
      ActsAsTenant.with_tenant(organisation) do
        create(:smart_folder_share, smart_folder: folder, user: lena)
        create(:smart_folder_share, smart_folder: folder, user: nina)
      end

      get share_organisation_smart_folder_path(organisation, folder)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('lena.team@example.com')
      expect_no_hidden_login_address(response.body)
    end

    it 'names the owner of a shared folder in the list by name' do
      ActsAsTenant.with_tenant(organisation) do
        create(:smart_folder, user: nina, organisation: organisation, project: project, target_object_type: 'Ticket',
                              name: 'Ninas Ordner').tap { |f| create(:smart_folder_share, smart_folder: f, user: admin) }
      end

      get organisation_smart_folders_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Ninas Ordner', 'Nina Beispiel')
      expect_no_hidden_login_address(response.body)
    end

    it 'names the owner of a shared folder without a hidden login address' do
      foreign = ActsAsTenant.with_tenant(organisation) do
        create(:smart_folder, user: lena, organisation: organisation, project: project, target_object_type: 'Ticket').tap do |f|
          create(:smart_folder_share, smart_folder: f, user: admin)
        end
      end

      get organisation_smart_folder_path(organisation, foreign)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(foreign.name)
      expect_no_hidden_login_address(response.body)
    end
  end

  describe 'the subscriber picker of a ticket' do
    let(:ticket) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, creator: admin) } }
    let(:path) { available_users_organisation_project_ticket_subscription_path(organisation, project, ticket) }

    it 'answers the shown email, null for a member who shows none' do
      get path, as: :json

      expect(response).to have_http_status(:ok)
      rows = response.parsed_body.index_by { |row| row['id'] }
      expect(rows.fetch(lena.id)['email']).to eq('lena.team@example.com')
      expect(rows.fetch(nina.id)['email']).to be_nil
      expect_no_hidden_login_address(response.body)
    end

    it 'names a member without a name like everywhere else' do
      ghost = member(nil, 'ghost-login@example.com', email_visibility: 'none')
      ghost.update_columns(last_name: nil)
      create(:project_permission, user: ghost, project: project, tickets_access: 'read_write')

      get path, as: :json

      row = response.parsed_body.find { |entry| entry['id'] == ghost.id }
      expect(row).to include('name' => I18n.t('users.unnamed'), 'email' => nil)
      expect(response.body).not_to include('ghost-login')
    end

    it 'searches the shown email, never a hidden login address' do
      get path, params: { q: 'lena.team' }, as: :json
      expect(response.parsed_body.pluck('id')).to include(lena.id)

      get path, params: { q: 'lena-login' }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq([])

      get path, params: { q: 'nina-login' }, as: :json
      expect(response.parsed_body).to eq([])
    end
  end

  describe 'the activity page of a member' do
    it 'shows the chosen email under the name' do
      get organisation_user_activities_path(organisation, user_id: lena.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('lena.team@example.com')
      expect_no_hidden_login_address(response.body)
    end
  end
end
