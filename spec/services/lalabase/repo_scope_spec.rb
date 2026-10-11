# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::RepoScope do
  describe '.ids_for' do
    let(:organisation) { create(:organisation) }

    before { ActsAsTenant.current_tenant = organisation }
    after  { ActsAsTenant.current_tenant = nil }

    # ⚠️ Turned around by projekt_chat_abbau, and this is the point of that change: the
    # pin used to be passed straight through, skipping the project and organisation
    # filters, on the strength of a Chat validation that cut removed. It NARROWS now.
    # Three directions, because "narrows" is only worth something if all three hold.
    it 'narrows to the pin when it belongs to the project' do
      project = create(:project, organisation: organisation)
      pinned = create(:project_repository, project: project, organisation: organisation)
      create(:project_repository, project: project, organisation: organisation)

      expect(
        described_class.ids_for(project: project, organisation: organisation, pinned_repo_id: pinned.id)
      ).to eq([pinned.id])
    end

    it 'returns [] for a pin naming a repository of ANOTHER project' do
      project = create(:project, organisation: organisation)
      create(:project_repository, project: project, organisation: organisation)
      foreign_project = create(:project, organisation: organisation)
      foreign = create(:project_repository, project: foreign_project, organisation: organisation)

      expect(
        described_class.ids_for(project: project, organisation: organisation, pinned_repo_id: foreign.id)
      ).to eq([])
    end

    it 'returns [] for a pin naming a repository of another ORGANISATION' do
      project = create(:project, organisation: organisation)
      create(:project_repository, project: project, organisation: organisation)

      other_org = create(:organisation)
      foreign = ActsAsTenant.with_tenant(other_org) do
        other_project = create(:project, organisation: other_org)
        create(:project_repository, project: other_project, organisation: other_org)
      end

      result = ActsAsTenant.without_tenant do
        described_class.ids_for(project: project, organisation: organisation, pinned_repo_id: foreign.id)
      end

      expect(result).to eq([])
    end

    it 'returns [] when project is nil, pin or no pin (defensive, no NoMethodError)' do
      expect(
        described_class.ids_for(project: nil, organisation: organisation, pinned_repo_id: 'pinned-uuid')
      ).to eq([])
    end

    it 'returns [] when project is nil and no pin (defensive, no NoMethodError)' do
      expect(
        described_class.ids_for(project: nil, organisation: organisation, pinned_repo_id: nil)
      ).to eq([])
    end

    it 'returns all org-scoped project repos when not pinned' do
      project = create(:project, organisation: organisation)
      repo_a = create(:project_repository, project: project, organisation: organisation)
      repo_b = create(:project_repository, project: project, organisation: organisation)
      expect(
        described_class.ids_for(project: project, organisation: organisation, pinned_repo_id: nil)
      ).to contain_exactly(repo_a.id, repo_b.id)
    end

    it 'returns [] for a project that has no repos (unindexed project)' do
      project = create(:project, organisation: organisation)
      expect(
        described_class.ids_for(project: project, organisation: organisation, pinned_repo_id: nil)
      ).to eq([])
    end

    it 'never returns repos belonging to another organisation' do
      project = create(:project, organisation: organisation)
      own = create(:project_repository, project: project, organisation: organisation)

      other_org = create(:organisation)
      ActsAsTenant.with_tenant(other_org) do
        other_project = create(:project, organisation: other_org)
        create(:project_repository, project: other_project, organisation: other_org)
      end

      result = ActsAsTenant.without_tenant do
        described_class.ids_for(project: project, organisation: organisation, pinned_repo_id: nil)
      end
      expect(result).to eq([own.id])
    end
  end
end
