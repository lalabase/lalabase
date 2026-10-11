# frozen_string_literal: true

# == Schema Information
#
# Table name: documentation_commits
#
#  id                   :uuid             not null, primary key
#  author_name          :string
#  commit_sha           :string           not null
#  committed_at         :datetime         not null
#  message              :string
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  documentation_set_id :uuid             not null
#  organisation_id      :uuid             not null
#
# Indexes
#
#  idx_documentation_commits_set_sha                    (documentation_set_id,commit_sha) UNIQUE
#  idx_documentation_commits_set_time                   (documentation_set_id,committed_at)
#  index_documentation_commits_on_documentation_set_id  (documentation_set_id)
#  index_documentation_commits_on_organisation_id       (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (documentation_set_id => documentation_sets.id)
#  fk_rails_...  (organisation_id => organisations.id)
#
require 'rails_helper'

# What: DocumentationCommit — logbook entry dedup per set + ordering.
# Type: Model spec.
# Why:  The logbook is append-only and fed repeatedly by every sync run; a
#       missing per-set SHA uniqueness would duplicate entries on each poll.
RSpec.describe DocumentationCommit, type: :model do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:set) { create(:documentation_set, project: create(:project, organisation: organisation)) }

  before { ActsAsTenant.current_tenant = organisation }

  describe 'validations' do
    it 'is valid with the factory' do
      expect(build(:documentation_commit, documentation_set: set)).to be_valid
    end

    it 'requires a commit_sha' do
      expect(build(:documentation_commit, documentation_set: set, commit_sha: nil)).not_to be_valid
    end

    it 'requires a committed_at' do
      expect(build(:documentation_commit, documentation_set: set, committed_at: nil)).not_to be_valid
    end

    it 'enforces a unique sha per set' do
      create(:documentation_commit, documentation_set: set, commit_sha: 'abc123')
      expect(build(:documentation_commit, documentation_set: set, commit_sha: 'abc123')).not_to be_valid
    end

    it 'allows the same sha in a different set (cross-scope)' do
      create(:documentation_commit, documentation_set: set, commit_sha: 'abc123')
      other_set = create(:documentation_set, project: create(:project, organisation: organisation))
      expect(build(:documentation_commit, documentation_set: other_set, commit_sha: 'abc123')).to be_valid
    end
  end

  # Defense in depth: the (documentation_set_id, commit_sha) unique index must
  # hold even if the model validation is bypassed.
  describe 'DB-level sha uniqueness' do
    it 'raises RecordNotUnique when the model validation is skipped' do
      create(:documentation_commit, documentation_set: set, commit_sha: 'abc123')
      dup = build(:documentation_commit, documentation_set: set, commit_sha: 'abc123')
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe '.recent' do
    it 'orders newest commit first' do
      old = create(:documentation_commit, documentation_set: set, committed_at: 2.days.ago)
      new = create(:documentation_commit, documentation_set: set, committed_at: 1.hour.ago)

      expect(DocumentationCommit.recent).to eq([new, old])
    end
  end

  describe '#short_sha' do
    it 'returns the first seven characters' do
      commit = build(:documentation_commit, commit_sha: 'abcdef1234567890')
      expect(commit.short_sha).to eq('abcdef1')
    end
  end

  describe 'tenant isolation' do
    it 'scopes commits to the tenant' do
      create(:documentation_commit, documentation_set: set)
      ActsAsTenant.with_tenant(other_organisation) { expect(DocumentationCommit.count).to eq(0) }
      expect(DocumentationCommit.count).to eq(1)
    end
  end
end
