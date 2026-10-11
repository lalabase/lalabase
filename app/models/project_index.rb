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
class ProjectIndex < ApplicationRecord
  self.table_name = 'project_indexes'

  STATUSES = %w[pending indexing ready failed stale].freeze
  LAYER_STATUSES = %w[pending indexing ready failed].freeze

  acts_as_tenant(:organisation)

  belongs_to :project_repository

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :layer_4_status, :layer_3_status, :layer_1_status,
            presence: true, inclusion: { in: LAYER_STATUSES }
  validates :layer_1_files_total, :layer_1_files_done, :index_version,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :project_repository_id, uniqueness: true

  scope :ready,    -> { where(status: 'ready') }
  scope :indexing, -> { where(status: 'indexing') }
  scope :failed,   -> { where(status: 'failed') }

  # Live status updates. Single broadcast source for BOTH ProjectIndexerJob and
  # RepoReindexJob (and any future writer) — they only call `update!`, so the
  # UI stays current without either job knowing about Turbo. Fires on status
  # transitions only: the per-file progress loop uses `update_columns`, which
  # skips callbacks, so a long index can't flood subscribers with broadcasts.
  after_update_commit :broadcast_status

  # Turbo replace target — MUST match the root id rendered by
  # Neo::Repository::IndexStatusComponent.
  def status_dom_id
    "project_index_#{id}_status"
  end

  def broadcast_status
    broadcast_replace_to(
      [organisation, :project_index, project_repository_id],
      target: status_dom_id,
      renderable: Neo::Repository::IndexStatusComponent.new(index: self)
    )
  rescue StandardError => e
    # A broadcast failure must never break the indexing job that triggered it.
    Rails.logger.error "ProjectIndex broadcast error: #{e.message}"
  end
end
