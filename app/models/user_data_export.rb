# frozen_string_literal: true

# A single self-service GDPR data export (Art. 15/20): requested by the user
# (with password re-auth), built asynchronously by UserDataExportJob, delivered
# as a ZIP attachment via a short-lived signed URL.
#
#   pending ──► processing ──► completed (expires_at = created + RETENTION)
#      │             │
#      └─────────────┴───────► failed
#
# Deliberately NOT acts_as_tenant: the export spans all of the user's
# organisations (like the user record itself). Tenant isolation happens inside
# UserDataExports::Builder (per-membership ActsAsTenant.with_tenant loop).
#
# Lifecycle guarantees:
# - Only ONE active (pending/processing) export per user — model validation for
#   the friendly message, partial unique index as the race-proof truth.
# - A FAILED export does not throttle: only completed/active requests count
#   towards REQUEST_INTERVAL, so an infrastructure failure never locks the user
#   out of their Art. 15 rights for 24h.
# - Archives are purged at expires_at (cleanup job) and, critically, when the
#   account is erased on EITHER path, self-service or admin backend
#   (PersonalDataErasure#erase_data_exports!, shared by both).
# == Schema Information
#
# Table name: user_data_exports
#
#  id            :uuid             not null, primary key
#  completed_at  :datetime
#  error_message :string
#  expires_at    :datetime
#  status        :string           default("pending"), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  user_id       :uuid             not null
#
# Indexes
#
#  idx_user_data_exports_one_active_per_user          (user_id) UNIQUE WHERE ((status)::text = ANY ((ARRAY['pending'::character varying, 'processing'::character varying])::text[]))
#  index_user_data_exports_on_user_id                 (user_id)
#  index_user_data_exports_on_user_id_and_created_at  (user_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
class UserDataExport < ApplicationRecord
  # How long a generated archive stays downloadable.
  RETENTION = 7.days
  # Minimum distance between two successful/active export requests per user.
  REQUEST_INTERVAL = 24.hours
  # Rows older than this are deleted entirely by the cleanup job (the archive
  # itself is already gone since expires_at).
  ROW_RETENTION = 30.days

  belongs_to :user
  has_one_attached :archive

  enum :status, {
    pending: 'pending',
    processing: 'processing',
    completed: 'completed',
    failed: 'failed'
  }, default: :pending

  validate :request_interval_respected, on: :create

  scope :active, -> { where(status: %w[pending processing]) }
  scope :expired, -> { completed.where(expires_at: ...Time.current) }
  scope :stale, -> { where(created_at: ...ROW_RETENTION.ago) }

  # Latest export that counts towards the request throttle (failed ones do not).
  def self.last_countable_for(user)
    where(user: user)
      .where(status: %w[pending processing completed])
      .order(created_at: :desc)
      .first
  end

  def downloadable?
    finished_with_expiry? && archive.attached? && expires_at.future?
  end

  def expired?
    finished_with_expiry? && expires_at.past?
  end

  private

  # Shared premise of downloadable?/expired?: only a completed export with a
  # set expiry has a meaningful download window at all.
  def finished_with_expiry?
    completed? && expires_at.present?
  end

  def request_interval_respected
    return if user.nil?

    previous = self.class.last_countable_for(user)
    return if previous.nil? || previous.created_at <= REQUEST_INTERVAL.ago

    errors.add(:base, :too_frequent)
  end
end
