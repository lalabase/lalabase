# frozen_string_literal: true

# One git commit that touched a DocumentationSet's path_prefix — the logbook
# entry (design premise 3c: `git log` is the v1 source of the logbook, no own
# diff-snapshot engine). Append-only; written by DocumentationSyncJob from the
# cloned repo's history, deduplicated per set by commit SHA.
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
class DocumentationCommit < ApplicationRecord
  acts_as_tenant(:organisation)

  belongs_to :documentation_set

  validates :commit_sha, presence: true, uniqueness: { scope: :documentation_set_id }
  validates :committed_at, presence: true

  scope :recent, -> { order(committed_at: :desc, commit_sha: :asc) }

  def short_sha
    commit_sha.to_s.first(7)
  end
end
