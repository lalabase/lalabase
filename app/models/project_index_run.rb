# frozen_string_literal: true

# A single indexing run (full index or incremental push-reindex)
# as a history entry. Written at the end of ProjectIndexerJob /
# RepoReindexJob, on success AND failure. DELIBERATELY lean: one row per run,
# no per-file details (that would be a bloated "log"). Embedding costs
# live in AiUsage and are NOT duplicated here.
# == Schema Information
#
# Table name: project_index_runs
#
#  id                    :uuid             not null, primary key
#  commit_sha            :string
#  error_message         :text
#  files_count           :integer          default(0), not null
#  finished_at           :datetime         not null
#  incremental           :boolean          default(FALSE), not null
#  started_at            :datetime         not null
#  status                :string           not null
#  symbols_added         :integer          default(0), not null
#  symbols_removed       :integer          default(0), not null
#  trigger               :string           not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  organisation_id       :uuid             not null
#  project_repository_id :uuid             not null
#  triggered_by_user_id  :uuid
#
# Indexes
#
#  idx_on_project_repository_id_created_at_faef1120bf  (project_repository_id,created_at)
#  index_project_index_runs_on_organisation_id         (organisation_id)
#  index_project_index_runs_on_triggered_by_user_id    (triggered_by_user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_repository_id => project_repositories.id)
#  fk_rails_...  (triggered_by_user_id => users.id) ON DELETE => nullify
#
class ProjectIndexRun < ApplicationRecord
  acts_as_tenant(:organisation)

  belongs_to :project_repository
  belongs_to :triggered_by_user, class_name: 'User', optional: true

  # initial = first index when connecting; push = GitHub push webhook (incremental
  # or fallback full index); manual = triggered manually (no UI trigger yet,
  # but prepared as a valid value).
  TRIGGERS = %w[initial manual push].freeze
  STATUSES = %w[ready failed].freeze

  validates :trigger, presence: true, inclusion: { in: TRIGGERS }
  validates :status,  presence: true, inclusion: { in: STATUSES }
  validates :started_at, :finished_at, presence: true
  validates :files_count, :symbols_added, :symbols_removed,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # id as a tie-break: two runs can share the same created_at second tick
  # (fast pushes) — without a second criterion their order would be undefined.
  scope :recent, -> { order(created_at: :desc, id: :desc) }

  # Runtime in seconds — directly answers "did that go suspiciously fast?".
  def duration_seconds
    return nil unless started_at && finished_at

    (finished_at - started_at).round
  end

  def failed?
    status == 'failed'
  end
end
