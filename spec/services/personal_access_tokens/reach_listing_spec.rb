# frozen_string_literal: true

require 'rails_helper'

# What: PersonalAccessTokens::ReachListing, the one read of a token's organisations
#       and projects behind GET /api/v1/organisations, GET /api/v1/projects and the
#       MCP tools list_organisations and list_projects.
# Type: Service spec.
# Why:  The reach of a token stood by hand at several doors and went wrong there more
#       than once. Three things must hold: the token AND the owner's rights decide; each
#       organisation answers with its own projects (the controller helper memoised
#       per scope object and answered the first one's for all); archived projects stay
#       an admin's, whatever the caller asks for.
RSpec.describe PersonalAccessTokens::ReachListing, :ci_guard do
  let(:user) { create(:user) }
  let(:organisation) { create(:organisation, name: 'Beta') }
  let(:other_organisation) { create(:organisation, name: 'Alpha') }
  let(:outside_organisation) { create(:organisation, name: 'Outside') }

  def project_in(org, **attributes)
    ActsAsTenant.with_tenant(org) { create(:project, organisation: org, **attributes) }
  end

  def admin_in(org)
    ActsAsTenant.with_tenant(org) do
      Membership.find_by!(user: user, organisation: org).update!(role: create(:admin_role, organisation: org))
    end
    user.instance_variable_set(:@role_cache, nil)
  end

  def listing(token) = described_class.new(reach: token.reach)

  describe '#organisations' do
    before do
      make_token_owner_a_member(user, organisation)
      make_token_owner_a_member(user, other_organisation)
    end

    it 'names each organisation in reach, by name, with its scope' do
      project = project_in(organisation)
      token = create(:personal_access_token, user: user, organisations: [organisation, other_organisation],
                                             project_scopes: { organisation => [project] })

      expect(listing(token).organisations).to eq(
        [{ id: other_organisation.id, name: 'Alpha', subdomain: other_organisation.subdomain, scope: 'all_projects' },
         { id: organisation.id, name: 'Beta', subdomain: organisation.subdomain, scope: 'selected_projects' }]
      )
    end

    it 'leaves out an organisation whose membership was deactivated' do
      token = create(:personal_access_token, user: user, organisations: [organisation, other_organisation])
      Membership.find_by!(user: user, organisation: organisation).update!(active: false)

      expect(listing(token).organisations.pluck(:id)).to eq([other_organisation.id])
    end

    it 'covers every membership for an all-organisations token, which has no link rows' do
      token = create(:personal_access_token, :all_organisations, user: user)

      expect(listing(token).organisations.pluck(:name)).to eq(%w[Alpha Beta])
    end
  end

  describe '#projects' do
    let(:zeta) { project_in(organisation, name: 'Zeta') }
    let(:eta) { project_in(organisation, name: 'Eta') }
    let(:foreign) { project_in(other_organisation, name: 'Foreign') }

    # Paused: the grants repeat their lookups per project, which is the setup and not the read.
    before do
      Prosopite.pause do
        make_token_owner_a_member(user, organisation, projects: [zeta, eta])
        make_token_owner_a_member(user, other_organisation, projects: [foreign])
      end
    end

    it 'answers each organisation with its own projects, by organisation, then by name' do
      token = create(:personal_access_token, user: user, organisations: [organisation, other_organisation])

      expect(listing(token).projects(viewer: user).pluck(:name)).to eq(%w[Foreign Eta Zeta])
    end

    it 'carries the row of the API' do
      token = create(:personal_access_token, user: user, organisations: [other_organisation])

      expect(listing(token).projects(viewer: user)).to eq(
        [{ id: foreign.id, name: 'Foreign', description: foreign.description, archived: false, meeting_inbox: false,
           organisation: { id: other_organisation.id, name: 'Alpha' },
           created_at: foreign.created_at.iso8601, updated_at: foreign.updated_at.iso8601 }]
      )
    end

    it 'keeps to the projects a limited token is linked to' do
      token = create(:personal_access_token, user: user, organisations: [organisation],
                                             project_scopes: { organisation => [eta] })

      expect(listing(token).projects(viewer: user).pluck(:id)).to eq([eta.id])
    end

    it 'keeps to the projects the owner may read, even with an all-projects token' do
      unreadable = project_in(organisation, name: 'Unreadable')
      token = create(:personal_access_token, user: user, organisations: [organisation])

      expect(listing(token).projects(viewer: user).pluck(:id)).not_to include(unreadable.id)
    end

    it 'narrows to the organisations asked for, and an id outside the reach adds nothing' do
      token = create(:personal_access_token, user: user, organisations: [organisation])
      project_in(outside_organisation)

      expect(listing(token).projects(viewer: user, organisation_ids: [organisation.id]).pluck(:name)).to eq(%w[Eta Zeta])
      expect(listing(token).projects(viewer: user, organisation_ids: [outside_organisation.id])).to eq([])
      expect(listing(token).projects(viewer: user, organisation_ids: [])).to eq([])
    end

    it 'answers nothing to a limited token whose links are gone, never the whole organisation' do
      token = create(:personal_access_token, user: user, organisations: [organisation],
                                             project_scopes: { organisation => [eta] })
      token.personal_access_token_projects.delete_all

      expect(listing(token.reload).projects(viewer: user)).to eq([])
    end

    it 'answers an empty list to a member without a project' do
      stranger = create(:user)
      make_token_owner_a_member(stranger, organisation)
      token = create(:personal_access_token, user: stranger, organisations: [organisation])

      expect(listing(token).projects(viewer: stranger)).to eq([])
    end

    it 'leaves no tenant behind' do
      token = create(:personal_access_token, user: user, organisations: [organisation])

      listing(token).projects(viewer: user)

      expect(ActsAsTenant.current_tenant).to be_nil
    end

    # The gate of a project tool (ProjectAccessService.can_access_project?) counts the areas of
    # ProjectPermission; the policy scope counts every *_all_projects key of a role, time
    # tracking included. Walked over every key and every kind of grant, because the two
    # differ in only two of them.
    describe 'openable_only' do
      let(:stranger) { create(:user) }
      let(:project) { project_in(organisation, name: 'Matrix') }
      let(:token) { create(:personal_access_token, user: stranger, organisations: [organisation]) }

      role_keys = Permission::CATEGORIES[:projects].select { |key| key.match?(/\A(read|write)_access_.*_all_projects\z/) }
      grants = { 'no grant' => nil, 'read' => :read_only, 'write' => :read_write, 'no access' => :no_access }

      def member_with(role_key)
        role = create(:role, organisation: organisation)
        create(:permission, role: role, category: 'projects', action: role_key)
        create(:membership, user: stranger, organisation: organisation, role: role, active: true)
      end

      role_keys.product(grants.to_a).each do |role_key, (grant, level)|
        it "agrees with the gate for #{role_key} and #{grant}" do
          project
          ActsAsTenant.with_tenant(organisation) do
            member_with(role_key)
            create(:project_permission, user: stranger, project: project, tickets_access: level) if level
          end

          listed = listing(token).projects(viewer: stranger, openable_only: true).pluck(:id).include?(project.id)
          opens = ActsAsTenant.with_tenant(organisation) do
            AccessCheck::ProjectAccessService.can_access_project?(stranger, project)
          end

          expect(listed).to eq(opens)
        end
      end

      # members has no role key at all: a grant is the only way in through that area.
      ProjectPermission.access_areas.each do |area|
        it "lists a project opened by a grant in #{area} alone" do
          project
          ActsAsTenant.with_tenant(organisation) do
            create(:membership, user: stranger, organisation: organisation, role: create(:role, organisation: organisation),
                                active: true)
            levels = ProjectPermission.access_areas.to_h do |name|
              [:"#{name}_access", name == area ? :read_only : :no_access]
            end
            create(:project_permission, user: stranger, project: project, **levels)
          end

          listed = listing(token).projects(viewer: stranger, openable_only: true).pluck(:id)
          opens = ActsAsTenant.with_tenant(organisation) do
            AccessCheck::ProjectAccessService.can_access_project?(stranger, project)
          end

          expect(opens).to be true
          expect(listed).to eq([project.id])
        end
      end

      it 'leaves out a project only time tracking reaches, which the gate refuses' do
        ActsAsTenant.with_tenant(organisation) { project && member_with('read_access_time_tracking_all_projects') }

        expect(listing(token).projects(viewer: stranger).pluck(:id)).to include(project.id)
        expect(listing(token).projects(viewer: stranger, openable_only: true).pluck(:id)).not_to include(project.id)
      end
    end

    context 'with an archived project' do
      let!(:archived) { project_in(organisation, name: 'Archived', archived_at: 1.day.ago) }

      it 'shows it to an admin unless it is left out, and marks it' do
        admin_in(organisation)
        token = create(:personal_access_token, user: user, organisations: [organisation])

        rows = listing(token).projects(viewer: user)
        expect(rows.find { |row| row[:id] == archived.id }).to include(archived: true)
        expect(listing(token).projects(viewer: user, include_archived: false).pluck(:id)).not_to include(archived.id)
      end

      it 'never shows it to anybody else, whatever the caller asks for' do
        token = create(:personal_access_token, user: user, organisations: [organisation])

        expect(listing(token).projects(viewer: user, include_archived: true).pluck(:id)).not_to include(archived.id)
      end
    end
  end
end
