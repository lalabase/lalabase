# frozen_string_literal: true

# == Schema Information
#
# Table name: user_deletions
#
#  id                  :uuid             not null, primary key
#  canceled_at         :datetime
#  cancellation_reason :text
#  deleted_at          :datetime         not null
#  deleter_type        :string           not null
#  executed_at         :datetime
#  reason              :text
#  scheduled_at        :datetime
#  source              :string           not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  deleted_user_id     :uuid             not null
#  deleter_id          :uuid             not null
#
# Indexes
#
#  index_user_deletions_on_deleted_at                   (deleted_at)
#  index_user_deletions_on_deleted_user_id              (deleted_user_id)
#  index_user_deletions_on_deleter_type_and_deleter_id  (deleter_type,deleter_id)
#  index_user_deletions_on_source                       (source)
#
# Foreign Keys
#
#  fk_rails_...  (deleted_user_id => users.id)
#
class UserDeletion < ApplicationRecord
  # Associations
  #
  # The referenced user is ALWAYS soft-deleted by the time an audit row is read,
  # so the association has to see through User's soft-delete default_scope.
  # `unscope(where: :deleted_at)` strips exactly that condition. NOTE: do not go
  # back to `-> { with_deleted }` / `-> { unscoped }` here — an `unscoped` inside
  # a belongs_to scope lambda does NOT compose, the default_scope's
  # `deleted_at IS NULL` survives and the reader returns nil for the deleted users
  # it is meant to resolve (regression-guarded in the model spec).
  belongs_to :deleted_user, -> { unscope(where: :deleted_at) }, class_name: 'User', foreign_key: 'deleted_user_id'

  # Polymorphic association for the deleter (User or Beuser)
  belongs_to :deleter, polymorphic: true

  # Validations
  validates :deleter_type, inclusion: { in: %w[User Beuser] }
  validates :source, inclusion: { in: %w[selfservice backend] }
  validates :deleted_at, presence: true
  validates :reason, length: { maximum: 500 }

  # Scopes
  scope :by_user, -> { where(deleter_type: 'User') }
  scope :by_beuser, -> { where(deleter_type: 'Beuser') }
  scope :selfservice_deletions, -> { where(source: 'selfservice') }
  scope :backend_deletions, -> { where(source: 'backend') }
  scope :recent_first, -> { order(deleted_at: :desc) }

  # Class methods
  def self.log_deletion(deleted_user:, deleter:, source:, reason: nil, scheduled_at: nil, executed_at: nil)
    # Store the original email before any potential associations are checked
    deleted_user.email

    # Create the audit log entry manually to avoid association validation issues
    audit_entry = new(
      deleted_user_id: deleted_user.id,
      deleter: deleter,
      source: source,
      reason: reason,
      deleted_at: executed_at || scheduled_at || Time.current,
      scheduled_at: scheduled_at,
      executed_at: executed_at
    )

    # Save without validating associations that might fail due to soft deletion
    audit_entry.save!(validate: false)
    audit_entry
  end

  # Instance methods
  def deleter_name
    case deleter_type
    when 'User'
      deleter.full_name
    when 'Beuser'
      "#{deleter.firstname} #{deleter.lastname} (Backend)"
    end
  end

  def self_service_deletion?
    source == 'selfservice'
  end

  def backend_deletion?
    source == 'backend'
  end
end
