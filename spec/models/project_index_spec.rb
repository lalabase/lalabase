# frozen_string_literal: true

# == Schema Information
#
# Table name: project_indexes
#
#  id                    :uuid             not null, primary key
#  error_message         :text
#  index_version         :integer          default(1), not null
#  last_indexed_at       :datetime
#  last_indexed_commit   :string
#  layer_1_files_done    :integer          default(0), not null
#  layer_1_files_total   :integer          default(0), not null
#  layer_1_status        :string           default("pending"), not null
#  layer_3_status        :string           default("pending"), not null
#  layer_4_status        :string           default("pending"), not null
#  status                :string           default("pending"), not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  organisation_id       :uuid             not null
#  project_repository_id :uuid             not null
#
# Indexes
#
#  index_project_indexes_on_organisation_id        (organisation_id)
#  index_project_indexes_on_project_repository_id  (project_repository_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_repository_id => project_repositories.id)
#
require 'rails_helper'

RSpec.describe ProjectIndex, type: :model do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  describe 'validations' do
    subject { build(:project_index) }

    it { is_expected.to be_valid }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_inclusion_of(:layer_4_status).in_array(described_class::LAYER_STATUSES) }
  end

  describe 'associations' do
    it { is_expected.to belong_to(:project_repository) }
  end

  describe 'uniqueness of project_repository_id' do
    it 'allows only one index per repository' do
      first = create(:project_index)
      dup   = build(:project_index, project_repository: first.project_repository,
                                    organisation: first.organisation)
      expect(dup).not_to be_valid
    end
  end

  describe 'tenant scoping' do
    it 'is scoped to current tenant' do
      mine = create(:project_index)
      ActsAsTenant.with_tenant(create(:organisation)) do
        theirs = create(:project_index)
        expect(described_class.all).to contain_exactly(theirs)
      end
      expect(described_class.all).to contain_exactly(mine)
    end
  end

  describe 'status whitelist (overall)' do
    described_class::STATUSES.each do |s|
      it "accepts #{s.inspect}" do
        expect(build(:project_index, status: s)).to be_valid
      end
    end

    %w[archived done STALE].each do |bad|
      it "rejects #{bad.inspect}" do
        expect(build(:project_index, status: bad)).not_to be_valid
      end
    end
  end

  describe 'layer status whitelist (no stale on layer level)' do
    described_class::LAYER_STATUSES.each do |s|
      it "accepts #{s.inspect} on layer_4_status" do
        expect(build(:project_index, layer_4_status: s)).to be_valid
      end
    end

    it 'rejects stale on layer_4_status (only valid for overall status)' do
      expect(build(:project_index, layer_4_status: 'stale')).not_to be_valid
    end
  end

  describe 'numericality boundaries' do
    it 'allows zero (initial state)' do
      expect(build(:project_index, layer_1_files_done: 0, layer_1_files_total: 0)).to be_valid
    end

    it 'rejects -1 on layer_1_files_done' do
      expect(build(:project_index, layer_1_files_done: -1)).not_to be_valid
    end

    it 'rejects -1 on layer_1_files_total' do
      expect(build(:project_index, layer_1_files_total: -1)).not_to be_valid
    end
  end

  describe 'defaults at DB level' do
    it 'defaults status fields to "pending" when omitted on insert' do
      # ProjectRepository auto-creates its ProjectIndex via after_create_commit.
      # We therefore inspect that auto-created row instead of creating a
      # second one (which would violate the uniqueness constraint).
      repo = create(:project_repository, organisation: organisation)
      idx = ProjectIndex.find_by!(project_repository_id: repo.id)
      expect(idx.reload).to have_attributes(
        status: 'pending', layer_4_status: 'pending',
        layer_3_status: 'pending', layer_1_status: 'pending',
        layer_1_files_total: 0, layer_1_files_done: 0,
        index_version: 1
      )
    end
  end

  describe 'DB-level uniqueness (defense in depth)' do
    it 'raises RecordNotUnique when model validation is bypassed' do
      first = create(:project_index)
      racer = build(:project_index, project_repository: first.project_repository,
                                    organisation: first.organisation)
      expect { racer.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe 'cascade on project_repository destroy' do
    it 'is destroyed when its project_repository is destroyed' do
      index = create(:project_index)
      repo  = index.project_repository
      expect { repo.destroy! }.to change(described_class, :count).by(-1)
    end
  end

  describe 'multi-repo per project' do
    it 'allows distinct indexes for distinct repositories of the same project' do
      project = create(:project, organisation: organisation)
      repo_a = create(:project_repository, project: project, full_name: 'acme/backend')
      repo_b = create(:project_repository, project: project, full_name: 'acme/frontend')
      idx_a = create(:project_index, project_repository: repo_a)
      idx_b = create(:project_index, project_repository: repo_b)
      expect(described_class.where(project_repository: project.project_repositories)).to contain_exactly(idx_a, idx_b)
    end
  end

  describe 'status scopes' do
    it 'partitions records by status' do
      ready    = create(:project_index, status: 'ready')
      indexing = create(:project_index, status: 'indexing')
      failed   = create(:project_index, status: 'failed')
      expect(described_class.ready).to contain_exactly(ready)
      expect(described_class.indexing).to contain_exactly(indexing)
      expect(described_class.failed).to contain_exactly(failed)
    end
  end

  describe 'live status broadcast' do
    let(:index) { create(:project_index, status: 'pending') }

    it 'broadcasts a replace to the per-repo index stream targeting the status dom id' do
      expect(index).to receive(:broadcast_replace_to).with(
        [organisation, :project_index, index.project_repository_id],
        hash_including(target: index.status_dom_id)
      )
      index.update!(status: 'indexing')
    end

    it 'renders the IndexStatusComponent into the broadcast' do
      expect(index).to receive(:broadcast_replace_to) do |*_streamables, **kwargs|
        expect(kwargs[:renderable]).to be_a(Neo::Repository::IndexStatusComponent)
      end
      index.update!(status: 'ready')
    end

    # The per-file progress loop uses update_columns (no callbacks); a long
    # index must NOT flood subscribers with a broadcast per file.
    it 'does not broadcast on update_columns' do
      index # create before setting the expectation
      expect(index).not_to receive(:broadcast_replace_to)
      index.update_columns(layer_1_files_done: 5)
    end

    it 'swallows broadcast errors so a failing cable never breaks the indexer' do
      allow(index).to receive(:broadcast_replace_to).and_raise(StandardError, 'cable down')
      expect { index.update!(status: 'failed') }.not_to raise_error
    end

    # Connected block: model broadcast → IndexStatusComponent → rendered HTML.
    # broadcast_status RESCUES errors, so a component that breaks in a background
    # (request-less) render would fail SILENTLY. Render the captured renderable
    # exactly as Turbo's `renderable:` broadcast does to prove the chain works
    # AND carries the new status for THIS index.
    it 'broadcasts a renderable that renders to HTML reflecting the new status' do
      captured = nil
      allow(index).to receive(:broadcast_replace_to) { |*_streamables, **kwargs| captured = kwargs[:renderable] }

      index.update!(status: 'ready')

      expect(captured).to be_a(Neo::Repository::IndexStatusComponent)
      # layout: false mirrors a Turbo broadcast (renders the component only, no
      # application layout / Devise).
      html = ApplicationController.render(captured, layout: false)
      expect(html).to include(I18n.t('views.organisations.indexing.status.ready'))
      expect(html).to include(index.status_dom_id) # targets THIS index, not another
    end
  end

  describe '#status_dom_id' do
    it 'is stable and unique per record' do
      a = create(:project_index)
      expect(a.status_dom_id).to eq("project_index_#{a.id}_status")
    end
  end
end
