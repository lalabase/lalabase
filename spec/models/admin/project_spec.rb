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
end
