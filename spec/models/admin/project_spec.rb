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

RSpec.describe Admin::Project, type: :model do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation, name: 'Other Org') }
  let(:user) { create(:user) }
  let(:project) do
    described_class.create!(
      name: 'Test Project',
      description: 'A test project description',
      repository: 'https://github.com/test/repo',
      organisation_id: organisation.id
    )
  end

  before do
    ActsAsTenant.current_tenant = organisation
  end

  # ---------------------------------------------------------------------------
  # Table Configuration
  # ---------------------------------------------------------------------------
  describe 'table configuration' do
    it 'uses the projects table' do
      expect(described_class.table_name).to eq('projects')
    end

    it 'strips Admin namespace from model_name' do
      expect(described_class.model_name.name).to eq('Project')
      expect(described_class.model_name.singular).to eq('project')
      expect(described_class.model_name.plural).to eq('projects')
    end

    it 'is accessible across tenants without acts_as_tenant' do
      project_org_1 = described_class.create!(name: 'P1', organisation_id: organisation.id)
      project_org_2 = described_class.create!(name: 'P2', organisation_id: other_organisation.id)

      all_projects = described_class.where(id: [project_org_1.id, project_org_2.id])
      expect(all_projects).to contain_exactly(project_org_1, project_org_2)
    end
  end

  # ---------------------------------------------------------------------------
  # Constants
  # ---------------------------------------------------------------------------
  describe 'constants' do
    it 'defines SHORT_DESCRIPTION_LIMIT as 100' do
      expect(described_class::SHORT_DESCRIPTION_LIMIT).to eq(100)
    end

    it 'defines REPOSITORY_PROVIDERS as frozen hash with known providers' do
      expect(described_class::REPOSITORY_PROVIDERS).to be_frozen
      expect(described_class::REPOSITORY_PROVIDERS).to eq(
        'github.com' => 'GitHub',
        'gitlab.com' => 'GitLab',
        'bitbucket.org' => 'Bitbucket'
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Associations
  # ---------------------------------------------------------------------------
  describe 'associations' do
    it { is_expected.to belong_to(:organisation).class_name('Admin::Organisation') }
    it { is_expected.to have_many(:project_permissions).class_name('Admin::ProjectPermission').dependent(:destroy) }
    it { is_expected.to have_many(:users_with_access).through(:project_permissions) }
  end

  # ---------------------------------------------------------------------------
  # Scopes
  # ---------------------------------------------------------------------------
  describe 'scopes' do
    let!(:project_alpha) do
      described_class.create!(name: 'Alpha', organisation_id: organisation.id, created_at: 2.days.ago)
    end
    let!(:project_beta) do
      described_class.create!(name: 'Beta', organisation_id: organisation.id, created_at: 1.day.ago)
    end
    let!(:project_gamma) do
      described_class.create!(name: 'Gamma', organisation_id: other_organisation.id, created_at: Time.current)
    end

    describe '.ordered_by_name' do
      it 'returns projects alphabetically by name' do
        result = described_class.where(id: [project_alpha.id, project_beta.id, project_gamma.id])
                                .ordered_by_name
        expect(result).to eq([project_alpha, project_beta, project_gamma])
      end
    end

    describe '.ordered_by_organisation' do
      it 'orders by organisation name, then project name' do
        # other_organisation ("Other Org") sorts before organisation ("Test Organisation N")
        # Within same org: Alpha < Beta
        result = described_class.where(id: [project_alpha.id, project_beta.id, project_gamma.id])
                                .ordered_by_organisation
        expect(result.pluck(:id)).to eq([project_gamma, project_alpha, project_beta].map(&:id))
      end
    end

    describe '.ordered_by_creation' do
      it 'returns projects ordered by created_at' do
        result = described_class.where(id: [project_alpha.id, project_beta.id, project_gamma.id])
                                .ordered_by_creation
        expect(result).to eq([project_alpha, project_beta, project_gamma])
      end
    end

    describe '.with_description' do
      it 'excludes projects with nil description' do
        project_alpha.update_column(:description, nil)
        project_beta.update_column(:description, 'Has description')

        result = described_class.where(id: [project_alpha.id, project_beta.id]).with_description
        expect(result).to contain_exactly(project_beta)
      end

      it 'excludes projects with empty string description' do
        project_alpha.update_column(:description, '')
        project_beta.update_column(:description, 'Has description')

        result = described_class.where(id: [project_alpha.id, project_beta.id]).with_description
        expect(result).to contain_exactly(project_beta)
      end
    end

    describe '.with_repository' do
      it 'excludes projects with nil repository' do
        project_alpha.update_column(:repository, nil)
        project_beta.update_column(:repository, 'https://github.com/test')

        result = described_class.where(id: [project_alpha.id, project_beta.id]).with_repository
        expect(result).to contain_exactly(project_beta)
      end

      it 'excludes projects with empty string repository' do
        project_alpha.update_column(:repository, '')
        project_beta.update_column(:repository, 'https://github.com/test')

        result = described_class.where(id: [project_alpha.id, project_beta.id]).with_repository
        expect(result).to contain_exactly(project_beta)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #organisation_name
  # ---------------------------------------------------------------------------
  describe '#organisation_name' do
    it 'returns the organisation name' do
      expect(project.organisation_name).to eq(organisation.name)
    end
  end

  # ---------------------------------------------------------------------------
  # #display_name
  # ---------------------------------------------------------------------------
  describe '#display_name' do
    context 'when name is present' do
      it 'returns the name' do
        expect(project.display_name).to eq('Test Project')
      end
    end

    context 'when name is nil' do
      before { project.update_column(:name, nil) }

      it 'returns fallback with truncated UUID' do
        expect(project.display_name).to eq("Projekt #{project.id[0..7]}")
      end
    end

    context 'when name is empty string' do
      before { project.update_column(:name, '') }

      it 'returns fallback with truncated UUID' do
        expect(project.display_name).to eq("Projekt #{project.id[0..7]}")
      end
    end

    context 'when name is whitespace only' do
      before { project.update_column(:name, '   ') }

      it 'returns fallback with truncated UUID' do
        expect(project.display_name).to eq("Projekt #{project.id[0..7]}")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #short_description
  # ---------------------------------------------------------------------------
  describe '#short_description' do
    context 'when description is nil' do
      before { project.update_column(:description, nil) }

      it 'returns fallback text' do
        expect(project.short_description).to eq('Keine Beschreibung')
      end
    end

    context 'when description is empty string' do
      before { project.update_column(:description, '') }

      it 'returns fallback text' do
        expect(project.short_description).to eq('Keine Beschreibung')
      end
    end

    context 'when description is whitespace only' do
      before { project.update_column(:description, '   ') }

      it 'returns fallback text' do
        expect(project.short_description).to eq('Keine Beschreibung')
      end
    end

    context 'when description is shorter than limit' do
      before { project.update_column(:description, 'Short description') }

      it 'returns the full description' do
        expect(project.short_description).to eq('Short description')
      end
    end

    context 'when description is exactly at the limit' do
      let(:exact_description) { 'x' * 100 }

      before { project.update_column(:description, exact_description) }

      it 'returns the full description without truncation' do
        expect(project.short_description).to eq(exact_description)
        expect(project.short_description.length).to eq(100)
      end
    end

    context 'when description exceeds the limit' do
      let(:long_description) { 'x' * 150 }

      before { project.update_column(:description, long_description) }

      it 'truncates with ellipsis' do
        result = project.short_description
        expect(result).to end_with('...')
        expect(result.length).to eq(100)
      end
    end

    context 'when description is exactly one character over the limit' do
      let(:description_101) { 'x' * 101 }

      before { project.update_column(:description, description_101) }

      it 'truncates to exactly the limit' do
        result = project.short_description
        expect(result.length).to eq(100)
        expect(result).to end_with('...')
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #repository_info
  # ---------------------------------------------------------------------------
  describe '#repository_info' do
    context 'when repository is nil' do
      before { project.update_column(:repository, nil) }

      it { expect(project.repository_info).to eq('Kein Repository') }
    end

    context 'when repository is empty string' do
      before { project.update_column(:repository, '') }

      it { expect(project.repository_info).to eq('Kein Repository') }
    end

    context 'when repository is a GitHub URL' do
      before { project.update_column(:repository, 'https://github.com/org/repo') }

      it { expect(project.repository_info).to eq('GitHub') }
    end

    context 'when repository is a GitLab URL' do
      before { project.update_column(:repository, 'https://gitlab.com/org/repo') }

      it { expect(project.repository_info).to eq('GitLab') }
    end

    context 'when repository is a Bitbucket URL' do
      before { project.update_column(:repository, 'https://bitbucket.org/org/repo') }

      it { expect(project.repository_info).to eq('Bitbucket') }
    end

    context 'when repository is an unknown provider' do
      before { project.update_column(:repository, 'https://gitea.example.com/org/repo') }

      it { expect(project.repository_info).to eq('Externes Repository') }
    end

    context 'when repository is a self-hosted URL with known provider in subdomain' do
      before { project.update_column(:repository, 'https://my.github.com.mirror.local/repo') }

      it 'matches on domain substring' do
        expect(project.repository_info).to eq('GitHub')
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #total_users_with_access_count
  # ---------------------------------------------------------------------------
  describe '#total_users_with_access_count' do
    context 'when no permissions exist' do
      it 'returns 0' do
        expect(project.total_users_with_access_count).to eq(0)
      end
    end

    context 'when permissions exist' do
      let(:user_2) { create(:user) }

      before do
        create_project_permission(project, user, tickets_access: :read_only)
        create_project_permission(project, user_2, tickets_access: :read_write)
      end

      it 'returns the distinct count of users' do
        expect(project.total_users_with_access_count).to eq(2)
      end
    end

    context 'when soft-deleted permissions exist' do
      before do
        perm = create_project_permission(project, user, tickets_access: :read_only)
        perm.update_column(:deleted_at, Time.current)
      end

      it 'excludes soft-deleted permissions' do
        expect(project.total_users_with_access_count).to eq(0)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #users_with_read_access_count
  # ---------------------------------------------------------------------------
  describe '#users_with_read_access_count' do
    let(:user_2) { create(:user) }
    let(:user_3) { create(:user) }

    context 'when no permissions or time session permissions exist' do
      it 'returns 0' do
        expect(project.users_with_read_access_count).to eq(0)
      end
    end

    context 'with project_permissions only' do
      it 'counts users with read_only tickets_access' do
        create_project_permission(project, user, tickets_access: :read_only)

        expect(project.users_with_read_access_count).to eq(1)
      end

      it 'counts users with read_write tickets_access' do
        create_project_permission(project, user, tickets_access: :read_write)

        expect(project.users_with_read_access_count).to eq(1)
      end

      it 'counts users with read access in notes_access' do
        create_project_permission(project, user, notes_access: :read_only)

        expect(project.users_with_read_access_count).to eq(1)
      end

      it 'counts users with read access in chats_access' do
        create_project_permission(project, user, chats_access: :read_write)

        expect(project.users_with_read_access_count).to eq(1)
      end

      it 'counts users with read access in documents_access' do
        create_project_permission(project, user, documents_access: :read_only)

        expect(project.users_with_read_access_count).to eq(1)
      end

      it 'does not count users with no_access everywhere' do
        create_project_permission(project, user)

        expect(project.users_with_read_access_count).to eq(0)
      end

      it 'counts multiple users correctly' do
        create_project_permission(project, user, tickets_access: :read_only)
        create_project_permission(project, user_2, notes_access: :read_write)

        expect(project.users_with_read_access_count).to eq(2)
      end
    end

    context 'with time_session_permissions only' do
      # A member with no area access whose right is the time row alone. The
      # project permission behind it is what makes the row count at all.
      before { create_project_permission(project, user) }

      it 'does not count a time row without a project permission behind it' do
        TimeSessionPermission.create!(user_id: user_2.id, project_id: project.id, can_view_all: true)

        expect(project.users_with_read_access_count).to eq(0)
      end

      it 'counts users with can_view_own' do
        TimeSessionPermission.create!(
          user_id: user.id,
          project_id: project.id,
          can_view_own: true,
          can_view_all: false
        )

        expect(project.users_with_read_access_count).to eq(1)
      end

      it 'counts users with can_view_all' do
        TimeSessionPermission.create!(
          user_id: user.id,
          project_id: project.id,
          can_view_own: false,
          can_view_all: true
        )

        expect(project.users_with_read_access_count).to eq(1)
      end

      it 'does not count users without any view permission' do
        TimeSessionPermission.create!(
          user_id: user.id,
          project_id: project.id,
          can_view_own: false,
          can_view_all: false,
          can_create_own: true
        )

        expect(project.users_with_read_access_count).to eq(0)
      end
    end

    context 'with overlapping permissions' do
      it 'counts a user appearing in both sources only once' do
        create_project_permission(project, user, tickets_access: :read_only)
        TimeSessionPermission.create!(
          user_id: user.id,
          project_id: project.id,
          can_view_own: true
        )

        expect(project.users_with_read_access_count).to eq(1)
      end

      it 'counts distinct users across both sources' do
        create_project_permission(project, user, tickets_access: :read_only)
        create_project_permission(project, user_2)
        TimeSessionPermission.create!(
          user_id: user_2.id,
          project_id: project.id,
          can_view_own: true
        )

        expect(project.users_with_read_access_count).to eq(2)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #users_with_write_access_count
  # ---------------------------------------------------------------------------
  describe '#users_with_write_access_count' do
    let(:user_2) { create(:user) }

    context 'when no permissions exist' do
      it 'returns 0' do
        expect(project.users_with_write_access_count).to eq(0)
      end
    end

    context 'with project_permissions only' do
      it 'counts users with read_write tickets_access' do
        create_project_permission(project, user, tickets_access: :read_write)

        expect(project.users_with_write_access_count).to eq(1)
      end

      it 'does not count users with only read_only access' do
        create_project_permission(project, user, tickets_access: :read_only)

        expect(project.users_with_write_access_count).to eq(0)
      end

      it 'counts users with write access in any area' do
        create_project_permission(project, user, documents_access: :read_write)

        expect(project.users_with_write_access_count).to eq(1)
      end
    end

    context 'with time_session_permissions only' do
      before { create_project_permission(project, user) }

      it 'does not count a time row without a project permission behind it' do
        TimeSessionPermission.create!(user_id: user_2.id, project_id: project.id, can_create_own: true)

        expect(project.users_with_write_access_count).to eq(0)
      end

      it 'counts users with can_create_own' do
        TimeSessionPermission.create!(
          user_id: user.id,
          project_id: project.id,
          can_create_own: true,
          can_edit_own: false,
          can_edit_all: false
        )

        expect(project.users_with_write_access_count).to eq(1)
      end

      it 'counts users with can_edit_own' do
        TimeSessionPermission.create!(
          user_id: user.id,
          project_id: project.id,
          can_create_own: false,
          can_edit_own: true,
          can_edit_all: false
        )

        expect(project.users_with_write_access_count).to eq(1)
      end

      it 'counts users with can_edit_all' do
        TimeSessionPermission.create!(
          user_id: user.id,
          project_id: project.id,
          can_create_own: false,
          can_edit_own: false,
          can_edit_all: true
        )

        expect(project.users_with_write_access_count).to eq(1)
      end

      it 'does not count users with only view permissions' do
        TimeSessionPermission.create!(
          user_id: user.id,
          project_id: project.id,
          can_create_own: false,
          can_edit_own: false,
          can_edit_all: false,
          can_view_own: true,
          can_view_all: true
        )

        expect(project.users_with_write_access_count).to eq(0)
      end
    end

    context 'with overlapping permissions' do
      it 'counts a user appearing in both sources only once' do
        create_project_permission(project, user, tickets_access: :read_write)
        TimeSessionPermission.create!(
          user_id: user.id,
          project_id: project.id,
          can_create_own: true
        )

        expect(project.users_with_write_access_count).to eq(1)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #project_permissions_with_details
  # ---------------------------------------------------------------------------
  describe '#project_permissions_with_details' do
    let(:user_alice) { create(:user, email: 'alice@example.com') }
    let(:user_bob) { create(:user, email: 'bob@example.com') }

    before do
      create_project_permission(project, user_bob, tickets_access: :read_only)
      create_project_permission(project, user_alice, tickets_access: :read_write)
    end

    it 'returns permissions ordered by user email' do
      result = project.project_permissions_with_details
      # The includes(:user) + joins(:user) ensures users are preloaded
      emails = result.map { |pp| pp.user.email }
      expect(emails).to eq(%w[alice@example.com bob@example.com])
    end

    it 'eager loads user associations' do
      result = project.project_permissions_with_details.to_a
      # Verify associations are preloaded (no lazy load needed)
      expect(result.size).to eq(2)
      expect(result.first.association(:user)).to be_loaded
    end

    it 'uses INNER JOIN so orphaned permissions without user records are excluded' do
      # Verify joins(:user) is used (INNER JOIN semantics)
      sql = project.project_permissions_with_details.to_sql
      expect(sql).to include('INNER JOIN')
      expect(sql).to include('"users"')
    end
  end

  # ---------------------------------------------------------------------------
  # #has_users_with_*_access?
  # ---------------------------------------------------------------------------
  describe '#has_users_with_tickets_access?' do
    context 'when no permissions exist' do
      it { expect(project.has_users_with_tickets_access?).to be false }
    end

    context 'when a user has read_only tickets_access' do
      before { create_project_permission(project, user, tickets_access: :read_only) }

      it { expect(project.has_users_with_tickets_access?).to be true }
    end

    context 'when a user has read_write tickets_access' do
      before { create_project_permission(project, user, tickets_access: :read_write) }

      it { expect(project.has_users_with_tickets_access?).to be true }
    end

    context 'when all users have no_access for tickets' do
      before { create_project_permission(project, user, tickets_access: :no_access, notes_access: :read_write) }

      it { expect(project.has_users_with_tickets_access?).to be false }
    end
  end

  describe '#has_users_with_notes_access?' do
    context 'when no permissions exist' do
      it { expect(project.has_users_with_notes_access?).to be false }
    end

    context 'when a user has notes_access' do
      before { create_project_permission(project, user, notes_access: :read_only) }

      it { expect(project.has_users_with_notes_access?).to be true }
    end
  end

  describe '#has_users_with_documents_access?' do
    context 'when no permissions exist' do
      it { expect(project.has_users_with_documents_access?).to be false }
    end

    context 'when a user has documents_access' do
      before { create_project_permission(project, user, documents_access: :read_write) }

      it { expect(project.has_users_with_documents_access?).to be true }
    end
  end

  # ---------------------------------------------------------------------------
  # #access_summary
  # ---------------------------------------------------------------------------
  describe '#access_summary' do
    it 'returns a hash with all access statistics' do
      summary = project.access_summary

      expect(summary).to include(
        total_users: be_a(Integer),
        read_access_users: be_a(Integer),
        write_access_users: be_a(Integer),
        tickets_access: be_in([true, false]),
        notes_access: be_in([true, false]),
        documents_access: be_in([true, false])
      )
    end

    it 'returns correct values for a project with mixed permissions' do
      user_2 = create(:user)
      create_project_permission(project, user, tickets_access: :read_write, notes_access: :read_only)
      create_project_permission(project, user_2, documents_access: :read_only)

      summary = project.access_summary

      expect(summary[:total_users]).to eq(2)
      expect(summary[:read_access_users]).to eq(2)
      expect(summary[:write_access_users]).to eq(1)
      expect(summary[:tickets_access]).to be true
      expect(summary[:notes_access]).to be true
      expect(summary[:documents_access]).to be true
    end

    it 'returns zeros and falses for a project without permissions' do
      summary = project.access_summary

      expect(summary[:total_users]).to eq(0)
      expect(summary[:read_access_users]).to eq(0)
      expect(summary[:write_access_users]).to eq(0)
      expect(summary[:tickets_access]).to be false
      expect(summary[:notes_access]).to be false
      expect(summary[:documents_access]).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # #status_css_class
  # ---------------------------------------------------------------------------
  describe '#status_css_class' do
    context 'when users have access' do
      before { create_project_permission(project, user, tickets_access: :read_only) }

      it 'returns green CSS class' do
        expect(project.status_css_class).to eq('bg-green-100 text-green-800')
      end
    end

    context 'when no users have access' do
      it 'returns gray CSS class' do
        expect(project.status_css_class).to eq('bg-gray-100 text-gray-800')
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #repository_css_class
  # ---------------------------------------------------------------------------
  describe '#repository_css_class' do
    context 'when repository is present' do
      it 'returns blue CSS class' do
        expect(project.repository_css_class).to eq('bg-blue-100 text-blue-800')
      end
    end

    context 'when repository is nil' do
      before { project.update_column(:repository, nil) }

      it 'returns gray CSS class' do
        expect(project.repository_css_class).to eq('bg-gray-100 text-gray-800')
      end
    end

    context 'when repository is empty string' do
      before { project.update_column(:repository, '') }

      it 'returns gray CSS class' do
        expect(project.repository_css_class).to eq('bg-gray-100 text-gray-800')
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------
  private

  def create_project_permission(project, user, **access_overrides)
    defaults = {
      tickets_access: :no_access,
      notes_access: :no_access,
      chats_access: :no_access,
      documents_access: :no_access
    }

    Admin::ProjectPermission.create!(
      user_id: user.id,
      project_id: project.id,
      **defaults.merge(access_overrides)
    )
  end
end
