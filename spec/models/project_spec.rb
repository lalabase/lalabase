# frozen_string_literal: true

# == Schema Information
#
# Table name: projects
#
#  id              :uuid             not null, primary key
#  archived_at     :datetime
#  description     :text
#  name            :string
#  repository      :text
#  settings        :jsonb            not null
#  system_kind     :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  archived_by_id  :uuid
#  organisation_id :uuid             not null
#
# Indexes
#
#  idx_projects_on_org_and_system_kind  (organisation_id,system_kind) UNIQUE WHERE (system_kind IS NOT NULL)
#  index_projects_on_archived_at        (archived_at)
#  index_projects_on_organisation_id    (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (archived_by_id => users.id)
#
require 'rails_helper'

RSpec.describe Project, type: :model do
  let(:organisation) { create(:organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe 'validations' do
    it { should validate_presence_of(:name) }

    it 'validates uniqueness of name' do
      ActsAsTenant.with_tenant(organisation) do
        create(:project, name: 'Test Project')
        duplicate_project = build(:project, name: 'Test Project')
        expect(duplicate_project).not_to be_valid
        expect(duplicate_project.errors[:name]).to be_present
      end
    end

    # The name is display-only, so any real-world company or product name must
    # pass. The former ASCII whitelist rejected every umlaut, hyphen and slash.
    # One example per name: a loop inside one example trips Prosopite on the
    # per-record tenant lookup.
    [
      'Kröger Nutzfahrzeuge / Produktkonfigurator',
      'Müller-Lüdenscheidt',
      'R&D 2026',
      'Relaunch (Phase 1)',
      'Café "Élan"'
    ].each do |name|
      it "accepts the real-world name #{name.inspect}" do
        ActsAsTenant.with_tenant(organisation) do
          expect(build(:project, name: name)).to be_valid
        end
      end
    end

    # The contract that replaced the whitelist: one line, trimmed, no control or
    # format characters, bounded. Pinned because three sinks depend on it: the
    # assistant prompt, the Subject header of notification mails, the logs.
    describe 'name normalisation' do
      it 'trims the edges, so " Kröger " collides with an existing "Kröger"' do
        ActsAsTenant.with_tenant(organisation) do
          create(:project, name: 'Kröger')
          expect(build(:project, name: ' Kröger ')).not_to be_valid
        end
      end

      it 'collapses newlines, tabs and runs of spaces to one space' do
        expect(build(:project, name: "Kröger\r\n  Nutzfahrzeuge\tGmbH").name).to eq('Kröger Nutzfahrzeuge GmbH')
      end

      # NUL would make Postgres reject the row (a 500 instead of a message), the
      # escape byte would let a name repaint an operator's terminal from a rake
      # task, and the direction override would flip the name in every list.
      it 'drops control, zero-width and direction-override characters' do
        expect(build(:project, name: "Kr\u200Böger\u202E\u0000\e").name).to eq('Kröger')
      end

      it 'keeps the joiner that holds an emoji sequence together' do
        family = "Team \u{1F468}\u200D\u{1F469}"
        expect(build(:project, name: family).name).to eq(family)
      end

      # Not the whole format-character class: these are letters in practice.
      it 'keeps the non-joiner of a Persian compound and the tag characters of a flag' do
        compound = "\u0645\u06CC\u200C\u062E\u0648\u0627\u0647\u0645"
        england = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        expect(build(:project, name: compound).name).to eq(compound)
        expect(build(:project, name: england).name).to eq(england)
      end

      # Order of the steps: invisible characters go first, otherwise "space,
      # zero-width space, space" collapses to a double space and the result is
      # not even idempotent.
      it 'leaves no double space where an invisible character sat between spaces' do
        expect(build(:project, name: "Kröger \u200B Nutz").name).to eq('Kröger Nutz')
      end

      it 'collapses no-break and ideographic spaces as well' do
        expect(build(:project, name: "Kröger\u00A0\u3000Nutz").name).to eq('Kröger Nutz')
      end

      it 'stores a decomposed umlaut composed, so it collides with the typed name' do
        ActsAsTenant.with_tenant(organisation) do
          create(:project, name: 'Kröger')
          decomposed = build(:project, name: "Kro\u0308ger")
          expect(decomposed.name).to eq('Kröger')
          expect(decomposed).not_to be_valid
        end
      end

      it 'rejects a name that is nothing but invisible characters' do
        p = build(:project, name: "\u200B\u200B")
        expect(p).not_to be_valid
        expect(p.errors[:name]).to be_present
      end
    end

    # n-1 / n / n+1 at the cap, so the boundary itself is what is pinned.
    it 'accepts NAME_MAX_LENGTH characters and rejects one more' do
      expect(build(:project, name: 'a' * (Project::NAME_MAX_LENGTH - 1))).to be_valid
      expect(build(:project, name: 'a' * Project::NAME_MAX_LENGTH)).to be_valid
      expect(build(:project, name: 'a' * (Project::NAME_MAX_LENGTH + 1))).not_to be_valid
    end

    it 'rejects a whitespace-only name (presence boundary)' do
      ActsAsTenant.with_tenant(organisation) do
        # Only the presence validation catches this (blank? treats whitespace as blank).
        p = build(:project, name: '   ')
        expect(p).not_to be_valid
        expect(p.errors[:name]).to be_present
      end
    end

    it 'allows the same name in a DIFFERENT organisation (scope: :organisation_id)' do
      # Kills the mutation "scope: :organisation_id removed" — without the scope the
      # name would be globally unique and invalid here.
      ActsAsTenant.with_tenant(organisation) { create(:project, name: 'Shared Name') }

      other_org = create(:organisation)
      ActsAsTenant.with_tenant(other_org) do
        expect(build(:project, name: 'Shared Name', organisation: other_org)).to be_valid
      end
    end
  end

  describe 'associations' do
    it { should have_many(:tickets).dependent(:destroy) }
    it { should have_many(:notes).dependent(:destroy) }
    it { should have_many(:documents).dependent(:destroy) }
    # projekt_chat_abbau: no chat belongs to a project any more. Pinned as an absence
    # because a resurrected `has_many :chats, dependent: :destroy` would silently start
    # deleting rows a project does not own.
    it { should_not have_many(:chats) }
    it { should have_many(:time_sessions).dependent(:destroy) }
    it { should have_many(:project_permissions).dependent(:destroy) }
    it { should have_many(:permitted_users).through(:project_permissions) }

    # Pin the remaining dependent associations — if someone removes the dependent:,
    # the respective matcher goes red (orphaned child records / data leak).
    it { should have_many(:ticket_attribute_definitions).dependent(:destroy) }
    it { should have_many(:time_session_permissions).dependent(:destroy) }
    it { should have_many(:personal_access_token_projects).dependent(:destroy) }
    it { should have_many(:smart_folders).dependent(:destroy) }
    it { should have_many(:view_configurations).dependent(:destroy) }
    it { should have_many(:dashboard_configurations).dependent(:destroy) }
    it { should have_many(:project_repositories).dependent(:destroy) }
    it { should have_many(:project_capabilities).dependent(:destroy) }
    it { should have_one(:project_layer4_vision).dependent(:destroy) }
    # codebase_import_files are NOT deleted along with it, but nullified (import history stays).
    it { should have_many(:codebase_import_files).dependent(:nullify) }
    it { should belong_to(:archived_by).class_name('User').optional }

    it 'belongs to organisation' do
      ActsAsTenant.without_tenant do
        project = Project.new(name: 'test', organisation_id: nil)
        expect(project).not_to be_valid
        expect(project.errors[:organisation]).to be_present
      end
    end

    it 'creates project with expected attributes' do
      ActsAsTenant.with_tenant(organisation) do
        project = create(:project, name: 'Test Project', description: 'Test Description')
        expect(project.name).to eq('Test Project')
        expect(project.description).to eq('Test Description')
        expect(project.repository).to eq('https://github.com/test/project')
      end
    end
  end

  describe 'multi-tenant behavior' do
    it 'belongs to an organisation' do
      ActsAsTenant.with_tenant(organisation) do
        project = create(:project)
        expect(project.organisation).to eq(organisation)
      end
    end

    it 'validates uniqueness of name scoped to organisation' do
      project1 = nil

      ActsAsTenant.with_tenant(organisation) do
        project1 = create(:project, name: 'Unique Name')
        project2 = build(:project, name: 'Unique Name')
        expect(project2).not_to be_valid
        expect(project2.errors[:name]).to be_present
      end
    end
  end

  describe 'settings (jsonb, NOT NULL, default {})' do
    it 'defaults to an empty hash on insert (NICHT via Factory gesetzt)' do
      ActsAsTenant.with_tenant(organisation) do
        project = create(:project) # Factory does not set settings
        expect(project.reload.settings).to eq({})
      end
    end

    it 'persistiert eine realistische verschachtelte Payload korrekt' do
      ActsAsTenant.with_tenant(organisation) do
        payload = { 'theme' => 'pop', 'flags' => { 'beta' => true }, 'order' => [3, 1, 2] }
        project = create(:project, settings: payload)
        expect(project.reload.settings).to eq(payload)
      end
    end

    it 'lehnt explizites nil ab (DB NOT NULL)' do
      ActsAsTenant.with_tenant(organisation) do
        expect { create(:project, settings: nil) }.to raise_error(ActiveRecord::NotNullViolation)
      end
    end
  end

  describe 'DB-Constraints (defense in depth)' do
    it 'wirft NOT NULL bei fehlender organisation, auch wenn die Validierung umgangen wird' do
      ActsAsTenant.without_tenant do
        project = build(:project, organisation: nil)
        expect { project.save!(validate: false) }.to raise_error(ActiveRecord::NotNullViolation)
      end
    end
  end

  describe '#users_with_access' do
    let(:organisation) { create(:organisation) }
    let(:project) { create(:project, organisation: organisation) }
    let(:user1) { create(:user) }
    let(:user2) { create(:user) }
    let(:user3) { create(:user) }
    let(:user4) { create(:user) }
    let(:admin_user) { create(:user) }

    before do
      ActsAsTenant.with_tenant(organisation) do
        # Create admin role and assign to admin_user
        admin_role = create(:role, organisation: organisation, title: 'account_admin')
        create(:membership, user: admin_user, organisation: organisation, role: admin_role)

        # Create a role with global read permission for tickets
        read_role = create(:role, organisation: organisation)
        create(:permission, role: read_role, category: 'projects', action: 'read_access_tickets_all_projects', allowed: true)
        create(:membership, user: user1, organisation: organisation, role: read_role)

        # Create a role with global write permission for tickets
        write_role = create(:role, organisation: organisation)
        create(:permission, role: write_role, category: 'projects', action: 'write_access_tickets_all_projects', allowed: true)
        create(:membership, user: user2, organisation: organisation, role: write_role)

        # Create a standard role with no special permissions
        standard_role = create(:role, organisation: organisation)
        create(:membership, user: user3, organisation: organisation, role: standard_role)
        create(:membership, user: user4, organisation: organisation, role: standard_role)

        # Give user3 direct project permission - read only for tickets
        create(:project_permission, user: user3, project: project, tickets_access: 'read_only')

        # Give user4 direct project permission - read write for tickets
        create(:project_permission, user: user4, project: project, tickets_access: 'read_write')
      end
    end

    context 'default arguments' do
      it 'defaultet auf (:read, :tickets) wenn ohne Argumente aufgerufen' do
        # Single call against the read-tickets contract (all 5 users). If the default flips
        # to :write -> 3 users, or to a different area -> different set -> red.
        ActsAsTenant.with_tenant(organisation) do
          users = project.users_with_access
          expect(users).to include(admin_user, user1, user2, user3, user4)
          expect(users.count).to eq(5)
        end
      end
    end

    context 'with read access for tickets area' do
      it 'returns users with various levels of access' do
        ActsAsTenant.with_tenant(organisation) do
          users = project.users_with_access(:read, :tickets)

          # Should include admin user
          expect(users).to include(admin_user)

          # Should include users with global read permission
          expect(users).to include(user1)

          # Should include users with global write permission (which implies read)
          expect(users).to include(user2)

          # Should include users with direct read permission
          expect(users).to include(user3)

          # Should include users with direct write permission (which implies read)
          expect(users).to include(user4)

          # Should have all 5 users
          expect(users.count).to eq(5)
        end
      end
    end

    context 'with write access for tickets area' do
      it 'returns only users with write access' do
        ActsAsTenant.with_tenant(organisation) do
          users = project.users_with_access(:write, :tickets)

          # Should include admin user
          expect(users).to include(admin_user)

          # Should NOT include users with only global read permission
          expect(users).not_to include(user1)

          # Should include users with global write permission
          expect(users).to include(user2)

          # Should NOT include users with only direct read permission
          expect(users).not_to include(user3)

          # Should include users with direct write permission
          expect(users).to include(user4)

          # Should have 3 users
          expect(users.count).to eq(3)
        end
      end
    end

    context 'with access for different areas' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          # Create a role with global read permission for notes only
          notes_role = create(:role, organisation: organisation)
          create(:permission, role: notes_role, category: 'projects', action: 'read_access_notes_all_projects', allowed: true)
          user3.memberships.first.update(role: notes_role)

          # Remove existing ticket permissions for user3 and user4
          ProjectPermission.where(user: [user3, user4], project: project).destroy_all

          # Add specific permissions
          create(:project_permission, user: user3, project: project, tickets_access: 'no_access', notes_access: 'read_only')
          create(:project_permission, user: user4, project: project, tickets_access: 'no_access', notes_access: 'read_write')
        end
      end

      it 'returns the correct users based on area' do
        ActsAsTenant.with_tenant(organisation) do
          # For tickets area
          ticket_users = project.users_with_access(:read, :tickets)
          expect(ticket_users).to include(admin_user)
          expect(ticket_users).to include(user1) # Has global read permission for tickets
          expect(ticket_users).to include(user2) # Has global write permission for tickets

          # For notes area
          note_users = project.users_with_access(:read, :notes)
          expect(note_users).to include(admin_user) # Admin has access to everything
          expect(note_users).to include(user3) # Has notes permission
          expect(note_users).to include(user4) # Has notes permission
        end
      end
    end
  end

  describe 'archiving' do
    let(:user) { create(:user) }
    let(:project) { create(:project, organisation: organisation) }

    describe '#archive!' do
      it 'sets archived_at and archived_by' do
        project.archive!(user)
        expect(project.archived_at).to be_present
        expect(project.archived_by).to eq(user)
      end

      it 'persistiert in die DB (nicht nur im Speicher — killt update->assign-Mutation)' do
        project.archive!(user)
        reloaded = Project.find(project.id)
        expect(reloaded.archived_at).to be_present
        expect(reloaded.archived_by).to eq(user)
      end
    end

    describe '#unarchive!' do
      it 'clears archived_at and archived_by' do
        project.archive!(user)
        project.unarchive!
        expect(project.archived_at).to be_nil
        expect(project.archived_by).to be_nil
      end
    end

    describe '#archived?' do
      it 'returns false for active projects' do
        expect(project.archived?).to be false
      end

      it 'returns true for archived projects' do
        project.archive!(user)
        expect(project.archived?).to be true
      end
    end

    describe 'scopes' do
      let!(:active_project) { create(:project, organisation: organisation) }
      let!(:archived_project) do
        p = create(:project, organisation: organisation)
        p.archive!(user)
        p
      end

      it '.active returns only non-archived projects' do
        expect(Project.active).to include(active_project)
        expect(Project.active).not_to include(archived_project)
      end

      it '.archived returns only archived projects' do
        expect(Project.archived).not_to include(active_project)
        expect(Project.archived).to include(archived_project)
      end
    end
  end

  describe 'dependency behavior' do
    let(:project) { create(:project, organisation: organisation) }

    it 'destroys dependent records when project is destroyed' do
      ActsAsTenant.with_tenant(organisation) do
        # Create associated records
        create(:ticket, project: project)
        create(:note, project: project)
        user = create(:user)
        create(:membership, user: user, organisation: organisation)
        create(:project_permission, user: user, project: project)
        create(:time_session, project: project)

        # Verify records exist
        expect(Ticket.count).to eq(1)
        expect(Note.count).to eq(1)
        expect(ProjectPermission.count).to eq(1)
        expect(TimeSession.count).to eq(1)

        # Destroy project
        expect do
          project.destroy
        end.to change(Project, :count).by(-1)

        # Verify all dependent records are destroyed
        expect(Ticket.count).to eq(0)
        expect(Note.count).to eq(0)
        # No Chat assertion: since projekt_chat_abbau a chat belongs to no project, so
        # destroying one destroys none. The absence is pinned in the associations
        # describe above (should_not have_many(:chats)).
        expect(ProjectPermission.count).to eq(0)
        expect(TimeSession.count).to eq(0)
      end
    end

    # Regression: a project with a single note could not be deleted at all.
    # ActionText::RichText declares `belongs_to :record, touch: true`, so destroying the
    # note's rich text defers a touch on the note; that touch is flushed in before_commit,
    # after the note row is gone. Because notes carry lock_version, the zero-row UPDATE
    # raised StaleObjectError instead of being a no-op and rolled the whole deletion back.
    # One note is enough to reproduce — the other dependents above are not involved.
    describe 'a project whose notes carry rich text (optimistic locking + ActionText)' do
      let(:project) { create(:project, organisation: organisation) }

      it 'is destroyable, and takes the note and its rich text with it' do
        note = ActsAsTenant.with_tenant(organisation) { create(:note, project: project) }
        expect(ActionText::RichText.where(record_type: 'Note', record_id: note.id)).to exist

        ActsAsTenant.with_tenant(organisation) do
          expect { project.destroy }.to change(Note, :count).by(-1)
        end

        expect(ActionText::RichText.where(record_type: 'Note', record_id: note.id)).not_to exist
      end
    end
  end

  describe '#one_line_name' do
    it 'keeps a short name whole' do
      expect(build(:project, name: 'Kröger Nutzfahrzeuge').one_line_name(max: 80)).to eq('Kröger Nutzfahrzeuge')
    end

    # The cap is the caller's number and has to bite AT it: n-1 whole, n whole,
    # n+1 cut (truncate keeps the ellipsis inside the number).
    it 'cuts at the cap and not one character later' do
      expect(build(:project, name: 'a' * 79).one_line_name(max: 80)).to eq('a' * 79)
      expect(build(:project, name: 'a' * 80).one_line_name(max: 80)).to eq('a' * 80)
      expect(build(:project, name: 'a' * 81).one_line_name(max: 80)).to eq("#{'a' * 77}...")
    end
  end
end
