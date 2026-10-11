# frozen_string_literal: true

# == Schema Information
#
# Table name: documentation_sets
#
#  id                    :uuid             not null, primary key
#  last_synced_at        :datetime
#  last_synced_commit    :string
#  name                  :string           not null
#  path_prefix           :string           default(".lalabase/doku/"), not null
#  sync_status           :string           default("never_synced"), not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  organisation_id       :uuid             not null
#  project_id            :uuid             not null
#  project_repository_id :uuid             not null
#
# Indexes
#
#  idx_documentation_sets_project_name                (project_id,name,organisation_id) UNIQUE
#  index_documentation_sets_on_organisation_id        (organisation_id)
#  index_documentation_sets_on_project_id             (project_id)
#  index_documentation_sets_on_project_repository_id  (project_repository_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (project_repository_id => project_repositories.id)
#
require 'rails_helper'

# What: DocumentationSet — validations, repo/project consistency, tenant
#       isolation, cascade to children.
# Type: Model spec.
# Why:  The set is the tenant-scoped root of a project's synced docs; a
#       mismatched repo or a cross-tenant leak would surface the wrong docs.
RSpec.describe DocumentationSet, type: :model do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  describe 'validations' do
    it 'is valid with the factory' do
      expect(build(:documentation_set, project: project)).to be_valid
    end

    it 'requires a name' do
      expect(build(:documentation_set, project: project, name: nil)).not_to be_valid
    end

    it 'requires a path_prefix' do
      expect(build(:documentation_set, project: project, path_prefix: nil)).not_to be_valid
    end

    it 'defaults path_prefix to the .lalabase/doku/ convention' do
      expect(DocumentationSet.new.path_prefix).to eq('.lalabase/doku/')
    end

    it 'defaults sync_status to never_synced' do
      expect(DocumentationSet.new.sync_status).to eq('never_synced')
    end

    it 'rejects an unknown sync_status' do
      expect(build(:documentation_set, project: project, sync_status: 'bogus')).not_to be_valid
    end

    it 'enforces a unique name per project' do
      create(:documentation_set, project: project, name: 'Handbuch')
      expect(build(:documentation_set, project: project, name: 'Handbuch')).not_to be_valid
    end

    it 'allows the same name in a different project' do
      create(:documentation_set, project: project, name: 'Handbuch')
      other_project = create(:project, organisation: organisation)
      expect(build(:documentation_set, project: other_project, name: 'Handbuch')).to be_valid
    end
  end

  # Defense in depth: the unique index must hold even if the model validation is
  # bypassed (TOCTOU race). save!(validate: false) simulates that DB path.
  describe 'DB-level name uniqueness' do
    it 'raises RecordNotUnique when the model validation is skipped' do
      first = create(:documentation_set, project: project, name: 'Handbuch')
      dup = build(:documentation_set, project: project, project_repository: first.project_repository, name: 'Handbuch')
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  # Positive iteration: shrinking SYNC_STATUSES must break something.
  describe 'sync_status whitelist' do
    DocumentationSet::SYNC_STATUSES.each do |status|
      it "accepts #{status.inspect}" do
        expect(build(:documentation_set, project: project, sync_status: status)).to be_valid
      end
    end
  end

  # Migration defaults are a contract. Values set via create! (NOT the factory)
  # so a dropped default breaks the test rather than being masked by the factory.
  describe 'insert-level defaults' do
    it 'defaults path_prefix and sync_status when omitted on insert' do
      repository = create(:project_repository, project: project, organisation: organisation)
      set = DocumentationSet.create!(organisation: organisation, project: project,
                                     project_repository: repository, name: 'Defaults')
      expect(set.reload).to have_attributes(path_prefix: '.lalabase/doku/', sync_status: 'never_synced')
    end
  end

  # Security: path_prefix is joined onto the clone dir by the sync job — a "/"
  # or "../" prefix would read files outside the cloned repository.
  describe 'path_prefix containment validation' do
    ['docs/', '.lalabase/doku/', 'a/b/c', '.', 'docs.v2/'].each do |good|
      it "accepts #{good.inspect}" do
        expect(build(:documentation_set, project: project, path_prefix: good)).to be_valid
      end
    end

    ['/etc', '/', '../', 'docs/../..', '..', 'a/../../b'].each do |bad|
      it "rejects #{bad.inspect}" do
        set = build(:documentation_set, project: project, path_prefix: bad)
        expect(set).not_to be_valid
        expect(set.errors[:path_prefix]).to be_present
      end
    end

    it 'accepts an inner "a/..%2Fb"-style name that merely CONTAINS dots' do
      # "docs.." is a weird but harmless folder name — only real ".." segments escape.
      expect(build(:documentation_set, project: project, path_prefix: 'docs../x')).to be_valid
    end
  end

  describe 'repository/project consistency' do
    it 'rejects a repository that belongs to a different project' do
      foreign_repo = create(:project_repository, organisation: organisation)
      set = build(:documentation_set, project: project, project_repository: foreign_repo)
      expect(set).not_to be_valid
      expect(set.errors[:project_repository]).to be_present
    end
  end

  describe 'tenant isolation' do
    it "does not expose one org's sets under another" do
      create(:documentation_set, project: project)
      ActsAsTenant.with_tenant(other_organisation) do
        expect(DocumentationSet.count).to eq(0)
      end
      expect(DocumentationSet.count).to eq(1)
    end
  end

  # One test per dependent association, so a removed `dependent:` breaks
  # exactly the association it belongs to (clear regression signal).
  describe 'cascade from the set (dependent: :delete_all)' do
    let(:set) { create(:documentation_set, project: project) }

    it 'deletes its pages' do
      create(:documentation_page, documentation_set: set)
      expect { set.destroy! }.to change(DocumentationPage, :count).by(-1)
    end

    it 'deletes its sync runs' do
      create(:documentation_sync_run, documentation_set: set)
      expect { set.destroy! }.to change(DocumentationSyncRun, :count).by(-1)
    end

    it 'deletes its per-user views' do
      create(:documentation_set_view, documentation_set: set)
      expect { set.destroy! }.to change(DocumentationSetView, :count).by(-1)
    end

    it 'deletes its logbook commits' do
      create(:documentation_commit, documentation_set: set)
      expect { set.destroy! }.to change(DocumentationCommit, :count).by(-1)
    end

    # The delete_all-trap (Slice 3): pages are removed via delete_all, which skips
    # the page's own dependent hook — so the set MUST purge the polymorphic
    # fragments itself in before_destroy, or gone docs keep grounding the chat.
    # Prepend order is what makes the subquery still see the pages; this test goes
    # red if the prepend (or the whole hook) is removed.
    it 'purges the polymorphic embedding fragments of its pages' do
      page = create(:documentation_page, documentation_set: set)
      fragment = create(:fragment, fragmentable: page, organisation: organisation)

      expect { set.destroy! }.to change { Fragment.where(id: fragment.id).count }.from(1).to(0)
    end

    it 'leaves another set fragments intact when one set is destroyed' do
      other_set = create(:documentation_set, project: project, name: 'Anderes Set')
      other_page = create(:documentation_page, documentation_set: other_set)
      survivor = create(:fragment, fragmentable: other_page, organisation: organisation)

      set.destroy!

      expect(Fragment.where(id: survivor.id)).to be_present
    end

    # Slice 4 twin of the fragment purge: pages also own outgoing Reference rows, and
    # delete_all skips that dependent hook too. Goes red if the reference purge (or the
    # prepend order) is dropped from before_destroy.
    it 'purges the outgoing references of its pages' do
      page = create(:documentation_page, documentation_set: set)
      note = create(:note, project: project, organisation: organisation)
      ref = Reference.create!(source: page, target: note, target_title_snapshot: 'T')

      expect { set.destroy! }.to change { Reference.where(id: ref.id).count }.from(1).to(0)
    end
  end

  describe '#syncing?' do
    it 'is true only while syncing' do
      expect(build(:documentation_set, sync_status: 'syncing')).to be_syncing
      expect(build(:documentation_set, sync_status: 'ready')).not_to be_syncing
    end
  end

  # Each predicate must match exactly its own status — a copy-paste mutant
  # (failed? checking 'ready') must die here.
  describe 'status predicates' do
    it 'maps each predicate to exactly one status' do
      expect(build(:documentation_set, sync_status: 'ready')).to be_ready
      expect(build(:documentation_set, sync_status: 'failed')).not_to be_ready
      expect(build(:documentation_set, sync_status: 'failed')).to be_failed
      expect(build(:documentation_set, sync_status: 'ready')).not_to be_failed
      expect(build(:documentation_set, sync_status: 'never_synced')).to be_never_synced
      expect(build(:documentation_set, sync_status: 'ready')).not_to be_never_synced
    end
  end
end
