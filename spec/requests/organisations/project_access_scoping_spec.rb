# frozen_string_literal: true

require 'rails_helper'

# Regression guard for the project-access leak across project pickers and project_id
# resolutions. A user with access to only project A must neither resolve nor see data
# from project B via parameter tampering. Single source of truth: selectable_projects
# (Organisations::ProjectScoping) → AccessCheck::ProjectAccessService. Org admins keep
# full access.
RSpec.describe 'Organisations project-access scoping', type: :request do
  let(:organisation) { create(:organisation) }

  let(:standard_role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end
  let(:admin_role) { create(:admin_role, organisation: organisation) }

  let(:member) do
    u = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
    end
    u
  end

  let(:admin) do
    u = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: u, organisation: organisation, role: admin_role, active: true)
    end
    u
  end

  let(:project_a) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:project_b) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  def grant(user, project, **areas)
    create(:project_permission, { user: user, project: project }.merge(areas))
  end

  # --- Category B: project_id resolution must be authorized (IDOR) ---
  describe 'GET project_repositories#index (set_project resolves params[:project_id])' do
    it 'denies a member resolving a project they cannot access' do
      grant(member, project_a, chats_access: 'read_only')
      sign_in member

      get organisation_project_project_repositories_path(organisation, project_b)

      expect(response).not_to have_http_status(:ok)
      expect(response).to have_http_status(:found).or have_http_status(:forbidden)
    end

    it 'allows a member to resolve a project they can access' do
      grant(member, project_a, chats_access: 'read_only')
      sign_in member

      get organisation_project_project_repositories_path(organisation, project_a)

      expect(response).to have_http_status(:ok)
    end

    it 'lets an org admin resolve any project (not locked out)' do
      sign_in admin

      get organisation_project_project_repositories_path(organisation, project_b)

      expect(response).to have_http_status(:ok)
    end
  end

  # --- Category C: filter-option endpoints must be authorized AND scoped ---
  describe 'GET smart_folders#field_operators (custom-attribute field config)' do
    let!(:foreign_attribute) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket_attribute_definition, project: project_b, name: 'secretfieldb', field_type: 'text')
      end
    end
    let!(:own_attribute) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket_attribute_definition, project: project_a, name: 'ownfielda', field_type: 'text')
      end
    end

    it 'does not expose custom-attribute fields from projects the member cannot access' do
      grant(member, project_a, tickets_access: 'read_only')
      sign_in member

      get organisation_field_operators_path(organisation, field: 'custom_secretfieldb')

      expect(response).to have_http_status(:bad_request)
    end

    it 'DOES expose custom-attribute fields from the member\'s own accessible project' do
      # Positive counterpart: scoping that is too aggressive (e.g. always an empty
      # project list) would also hide the user's own field. The admin test alone does
      # not cover this, because admins bypass the project scoping anyway.
      grant(member, project_a, tickets_access: 'read_only')
      sign_in member

      get organisation_field_operators_path(organisation, field: 'custom_ownfielda')

      expect(response).to have_http_status(:ok)
    end

    it 'uses tickets-area access: chats-only access does not expose ticket custom fields' do
      # Filter builder DELIBERATELY uses area: :tickets (custom attributes hang off tickets).
      # Catches the mutation area: :tickets -> area: nil, where a user with chats-only
      # access would see ticket field names even though they may not read the tickets.
      grant(member, project_a, chats_access: 'read_only')
      sign_in member

      get organisation_field_operators_path(organisation, field: 'custom_ownfielda')

      expect(response).to have_http_status(:bad_request)
    end

    it 'exposes the field to an org admin (not locked out)' do
      sign_in admin

      get organisation_field_operators_path(organisation, field: 'custom_secretfieldb')

      expect(response).to have_http_status(:ok)
    end
  end

  # --- People pickers must not leak identities from other projects ---
  describe 'subscription people pickers (cross-project identity leak)' do
    let(:b_only_user) do
      u = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
      end
      grant(u, project_b, tickets_access: 'read_only')
      u
    end
    let(:ticket_in_a) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project_a, organisation: organisation, creator: admin)
      end
    end

    describe 'GET available_users (autocomplete)' do
      before { grant(member, project_a, tickets_access: 'read_only') }

      it 'omits users who only have access to a different project' do
        b_only_user
        sign_in member

        get available_users_organisation_project_ticket_subscription_path(organisation, project_a, ticket_in_a)

        ids = JSON.parse(response.body).map { |u| u['id'] }
        expect(ids).not_to include(b_only_user.id)
      end

      it 'includes org admins (must stay subscribable)' do
        other_admin = create(:user)
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: other_admin, organisation: organisation, role: admin_role, active: true)
        end
        sign_in member

        get available_users_organisation_project_ticket_subscription_path(organisation, project_a, ticket_in_a)

        ids = JSON.parse(response.body).map { |u| u['id'] }
        expect(ids).to include(other_admin.id)
      end

      it 'includes a regular member who has direct access to the project' do
        # Positive counterpart beyond the admin case: pins that the direct-permission
        # path of users_with_access also carries through in the autocomplete (scoping
        # that is too aggressive would otherwise go unnoticed, because admins bypass
        # the access check).
        accessible_member = create(:user)
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: accessible_member, organisation: organisation, role: standard_role, active: true)
        end
        grant(accessible_member, project_a, tickets_access: 'read_only')
        sign_in member

        get available_users_organisation_project_ticket_subscription_path(organisation, project_a, ticket_in_a)

        ids = JSON.parse(response.body).map { |u| u['id'] }
        expect(ids).to include(accessible_member.id)
      end
    end

    describe 'GET available_users with a deactivated member' do
      it 'omits them, as the write refuses them' do
        gone = create(:user)
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: gone, organisation: organisation, role: admin_role, active: false)
        end
        grant(member, project_a, tickets_access: 'read_only')
        sign_in member

        get available_users_organisation_project_ticket_subscription_path(organisation, project_a, ticket_in_a)

        ids = JSON.parse(response.body).map { |u| u['id'] }
        expect(ids).not_to include(gone.id)
        expect(ids).to be_present
      end
    end

    describe 'POST subscribe_other' do
      it 'refuses to subscribe a user who has no access to the project' do
        b_only_user
        sign_in admin

        post subscribe_other_organisation_project_ticket_subscription_path(organisation, project_a, ticket_in_a),
             params: { user_id: b_only_user.id }

        expect(response).not_to have_http_status(:ok)
        ActsAsTenant.with_tenant(organisation) do
          expect(NotificationSubscription.find_by(user: b_only_user, subscribable: ticket_in_a)).to be_nil
        end
      end

      it 'subscribes a user who has access to the project' do
        accessible_user = create(:user)
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: accessible_user, organisation: organisation, role: standard_role, active: true)
        end
        grant(accessible_user, project_a, tickets_access: 'read_only')
        sign_in admin

        post subscribe_other_organisation_project_ticket_subscription_path(organisation, project_a, ticket_in_a),
             params: { user_id: accessible_user.id },
             headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
      end
    end
  end
end
