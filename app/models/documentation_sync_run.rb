# frozen_string_literal: true

# Append-only log of one sync attempt for a DocumentationSet (ProjectIndexRun
# pattern). A finished run is either 'ready' or 'failed'; on failure it carries
# one of six distinguishable error classes for a specific, actionable message.
# == Schema Information
#
# Table name: documentation_sync_runs
#
#  id                   :uuid             not null, primary key
#  assets_skipped       :integer          default(0), not null
#  assets_synced        :integer          default(0), not null
#  commit_sha           :string
#  error_class          :string
#  error_message        :text
#  finished_at          :datetime
#  pages_removed        :integer          default(0), not null
#  pages_synced         :integer          default(0), not null
#  started_at           :datetime
#  status               :string           not null
#  trigger              :string           not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  documentation_set_id :uuid             not null
#  organisation_id      :uuid             not null
#  triggered_by_user_id :uuid
#
# Indexes
#
#  idx_on_documentation_set_id_created_at_714010eb45      (documentation_set_id,created_at)
#  index_documentation_sync_runs_on_documentation_set_id  (documentation_set_id)
#  index_documentation_sync_runs_on_organisation_id       (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (documentation_set_id => documentation_sets.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (triggered_by_user_id => users.id) ON DELETE => nullify
#
class DocumentationSyncRun < ApplicationRecord
  acts_as_tenant(:organisation)

  STATUSES = %w[ready failed].freeze
  TRIGGERS = %w[manual polling webhook].freeze
  # DT4: six distinguishable sync error classes (nil on success).
  ERROR_CLASSES = %w[
    auth
    repo_unreachable
    path_not_found
    markdown_invalid
    asset_failed
    source_deleted
  ].freeze

  belongs_to :documentation_set
  belongs_to :triggered_by_user, class_name: 'User', optional: true

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :trigger, presence: true, inclusion: { in: TRIGGERS }
  validates :error_class, inclusion: { in: ERROR_CLASSES }, allow_nil: true

  scope :recent, -> { order(created_at: :desc, id: :desc) }

  def failed?
    status == 'failed'
  end

  def duration_seconds
    return if started_at.nil? || finished_at.nil?

    (finished_at - started_at).round
  end
end
