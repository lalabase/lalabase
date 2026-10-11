# frozen_string_literal: true

# == Schema Information
#
# Table name: beusers
#
#  id              :uuid             not null, primary key
#  active          :boolean          default(FALSE)
#  email           :string
#  firstname       :string
#  lastname        :string
#  password_digest :string
#  password_token  :string
#  role            :string           default("user")
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
class Beuser < ApplicationRecord
  # Same floor as a user password (Devise), for every way a beuser gets one.
  MINIMUM_PASSWORD_LENGTH = Devise.password_length.min
  # Serialises every "is another active admin left?" check (see last_active_admin?).
  ACTIVE_ADMIN_LOCK = 'beusers.last_active_admin'

  has_secure_password
  attr_accessor :check_password

  validates :email, presence: true
  validates :email, uniqueness: true
  validates :role, presence: true
  validates :password, presence: true, if: -> { check_password == true }, confirmation: true
  # has_secure_password alone accepts one character. allow_nil: an update that
  # does not touch the password leaves the attribute nil.
  validates :password, length: { minimum: MINIMUM_PASSWORD_LENGTH }, allow_nil: true
  validate :instance_keeps_an_active_admin, on: :update
  before_destroy :keep_the_last_active_admin

  store :permissions, accessors: %i[users statistics translations_with_formatting projects_stats]

  ROLES = %w[user admin].freeze

  def admin?
    role == 'admin'
  end

  def set_new_password(pwd, pwd_confirmation)
    self.check_password = true
    self.password = pwd
    self.password_confirmation = pwd_confirmation
  end

  def active_admin?
    admin? && active?
  end

  def permission?(permission)
    if admin?
      true
    elsif %w[users].include?(permission)
      (permissions || {})[permission.to_sym] == '1'
    else
      false
    end
  end

  private

  # Only an active admin can reach /admin, so demoting or deactivating the last
  # one locks the whole instance out of its admin area.
  def instance_keeps_an_active_admin
    return unless was_active_admin? && !active_admin?
    return unless last_active_admin?

    errors.add(:base, :last_active_admin)
  end

  def keep_the_last_active_admin
    return unless was_active_admin? && last_active_admin?

    errors.add(:base, :last_active_admin)
    throw :abort
  end

  def was_active_admin?
    role_in_database == 'admin' && active_in_database
  end

  # Two admins demoting each other at once would each still see the other one
  # as active, and both writes would pass. The transaction-scoped advisory lock
  # makes the second check wait until the first write commits; under READ
  # COMMITTED its query then sees that write. Validations and before_destroy run
  # inside the save/destroy transaction, so the lock covers the write itself.
  def last_active_admin?
    self.class.connection.execute(
      self.class.sanitize_sql_array(['SELECT pg_advisory_xact_lock(hashtext(?))', ACTIVE_ADMIN_LOCK])
    )
    !Beuser.where(role: 'admin', active: true).where.not(id: id).exists?
  end
end
