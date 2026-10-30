# frozen_string_literal: true

require 'bcrypt'

# Admin::User - User model without tenant restrictions for the admin backend.
# Uses the same table as User, but without acts_as_tenant.
# May ONLY be used in the admin area!

# == Schema Information
#
# Table name: users
#
#  id                      :uuid             not null, primary key
#  active                  :boolean          default(TRUE), not null
#  changelog_last_read_at  :datetime
#  confirmation_sent_at    :datetime
#  confirmation_token      :string
#  confirmed_at            :datetime
#  deleted_at              :datetime
#  deletion_canceled_at    :datetime
#  deletion_reason         :text
#  deletion_recommended    :boolean          default(FALSE), not null
#  email                   :string           default(""), not null
#  encrypted_password      :string           default(""), not null
#  failed_attempts         :integer          default(0), not null
#  first_name              :string
#  is_ai                   :boolean          default(FALSE)
#  language_preference     :string           default("de"), not null
#  last_name               :string
#  last_seen_at            :datetime
#  locked_at               :datetime
#  preferences             :jsonb            not null
#  remember_created_at     :datetime
#  reset_password_sent_at  :datetime
#  reset_password_token    :string
#  scheduled_deletion_at   :datetime
#  session_timeout_minutes :integer          default(30), not null
#  terms_accepted_at       :datetime
#  timezone                :string           default("Europe/Berlin")
#  unconfirmed_email       :string
#  unlock_token            :string
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  invited_by_org_id       :uuid
#  invited_by_user_id      :uuid
#
# Indexes
#
#  index_users_on_confirmation_token     (confirmation_token) UNIQUE
#  index_users_on_deleted_at             (deleted_at)
#  index_users_on_deletion_recommended   (deletion_recommended)
#  index_users_on_email_active           (email) UNIQUE WHERE (deleted_at IS NULL)
#  index_users_on_invited_by_org_id      (invited_by_org_id)
#  index_users_on_invited_by_user_id     (invited_by_user_id)
#  index_users_on_language_preference    (language_preference)
#  index_users_on_last_seen_at           (last_seen_at)
#  index_users_on_preferences            (preferences) USING gin
#  index_users_on_scheduled_deletion_at  (scheduled_deletion_at)
#  index_users_on_timezone               (timezone)
#  index_users_on_unlock_token           (unlock_token) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (invited_by_org_id => organisations.id)
#  fk_rails_...  (invited_by_user_id => users.id)
#
module Admin
  class User < ApplicationRecord
    self.table_name = 'users'

    include PersonalDataErasure

    # Prevents duplicate "admin" prefixes in URL helpers
    def self.model_name
      ActiveModel::Name.new(self, nil, 'User')
    end

    # NO acts_as_tenant - enables admin access across all tenants

    attr_accessor :password, :password_confirmation

    # Validations (must stay in sync with the regular User model)
    validates :email, presence: true, uniqueness: true
    validates :first_name, :last_name, presence: true
    validates :active, inclusion: { in: [true, false] }

    before_save :encrypt_password_if_present
    # Devise's :confirmable lives on ::User; Admin::User shares the table but
    # none of its modules, so nothing here would ever stamp confirmed_at — an
    # admin-created account would silently expire once the grace period ends
    # (allow_unconfirmed_access_for) WITHOUT ever having been sent a
    # confirmation mail. An admin hands the temporary password over personally,
    # which vouches for the address, so such an account counts as confirmed on
    # creation. Registered once here to cover both admin create paths (existing
    # organisation and fresh organisation).
    before_create :mark_confirmed

    # Associations (admin namespace for tenant bypass)
    has_many :memberships, class_name: 'Admin::Membership', dependent: :destroy
    has_many :organisations, through: :memberships, class_name: 'Admin::Organisation'
    has_many :project_permissions, class_name: 'Admin::ProjectPermission', dependent: :destroy
    has_many :permitted_projects, through: :project_permissions, source: :project, class_name: 'Admin::Project'

    # Billing accounts. Plain ::Account on purpose, no Admin:: shadow -- Account
    # was designed cross-tenant from the start, so there is nothing to bypass
    # (same reasoning as Admin::AccountsController).
    #
    # The two relations stay separate because they mean different things and
    # must not be collapsed into one list: owning an Account is a pure billing
    # role that grants NO access to its organisations' data (D4), while being a
    # member of one of its organisations says nothing about who pays.
    #
    # dependent: :nullify mirrors the FK (accounts.owner_id ON DELETE nullify),
    # so deleting a user leaves the Account behind as an orphan (badge in
    # Admin > Abrechnungskonten) instead of taking billing data with it.
    # inverse_of: false is deliberate, NOT an oversight: the other side is
    # `Account belongs_to :owner, class_name: 'User'` -- pointing at ::User, a
    # different class than this shadow model. An inverse would hand out
    # Admin::User instances through account.owner and quietly mix the two.
    has_many :owned_accounts, class_name: '::Account', foreign_key: :owner_id,
                              dependent: :nullify, inverse_of: false
    # distinct: a user with several memberships in organisations of the same
    # account would otherwise see that account once per organisation.
    has_many :accounts, -> { distinct }, through: :organisations, source: :account

    # Scopes
    scope :active, -> { where(active: true) }
    scope :inactive, -> { where(active: false) }
    scope :ordered_by_creation, -> { order(:created_at) }
    scope :ordered_by_email, -> { order(:email) }
    # The "Lalabase" system account (onboarding seed actor) is invisible to the
    # admin backend: index uses this scope, destroy is aborted below. Canonical
    # definition lives in User::SystemAccount.
    scope :without_system, -> { where.not(email: ::User::SystemAccount::EMAIL) }

    # Deletion fence for the system account: Admin::User bypasses the regular
    # User callbacks, so the shared fence concern is registered here as well
    # (one implementation, two registrations — see User::SystemAccount).
    include ::User::SystemAccount::DestroyFence

    # Name rendering owner (twin-parity with ::User, guard:
    # admin_twin_concern_parity_guard_spec). Pure read-only formatting, no
    # callbacks. S3 converged the former shadows: display_name comes from the
    # concern (bit-identical semantics, pinned in spec/models/admin/user_spec),
    # avatar_initials (single letter) became the concern's two-letter initials.
    # ONLY full_name still shadows — the admin backend's full_name falls back
    # to the email local part (several admin views and confirm dialogs rely on
    # it), while the concern's stays the raw unstripped pair.
    include ::User::NameDisplay

    # Which email the others see (twin-parity with ::User, same guard). The
    # admin backend itself keeps showing the login address; the concern keeps
    # the validations and the check-constraint values the same on both sides,
    # so an admin save cannot store a choice the app would refuse.
    include ::User::EmailDisplay

    # Display methods
    def full_name
      return email.split('@').first if first_name.blank? && last_name.blank?

      "#{first_name} #{last_name}".strip
    end

    def status_text
      active? ? 'Aktiv' : 'Inaktiv'
    end

    # Statistics methods (cross-tenant)
    def total_organisations_count
      memberships.joins(:organisation).distinct.count('organisations.id')
    end

    def active_memberships_count
      memberships.where(active: true).count
    end

    def total_projects_with_access_count
      project_permissions.count
    end

    def account_admin_organisations_count
      memberships.joins(:role).where('roles.title' => ::Role::ACCOUNT_ADMIN_TITLE).count
    end

    # Membership helper methods
    def membership_in_organisation(organisation_id)
      memberships.find_by(organisation_id: organisation_id)
    end

    def should_be_recommended_for_deletion?
      !deleted? && memberships.where(active: true).none?
    end

    def mark_for_deletion_review!
      update!(deletion_recommended: true) unless deleted?
    end

    def deleted?
      deleted_at.present?
    end

    def deletion_scheduled?
      scheduled_deletion_at.present? && scheduled_deletion_at > Time.current
    end

    def days_until_deletion
      return nil unless deletion_scheduled?

      ((scheduled_deletion_at - Time.current) / 1.day).ceil
    end

    def can_be_deleted_by?(requester, source = nil)
      return false if deleted?
      return false unless requester.is_a?(Beuser)
      return false if source && source != 'backend'

      true
    end

    def active_membership_in_organisation?(organisation_id)
      membership_in_organisation(organisation_id)&.active?
    end

    def role_in_organisation(organisation_id)
      membership_in_organisation(organisation_id)&.role
    end

    # GDPR anonymization
    def anonymize!
      update_columns(anonymization_attributes)
    end

    # Operator twin of User::DeletionLifecycle#soft_delete_and_anonymize!. This
    # model deliberately keeps its own copy (see the header of
    # user/deletion_lifecycle.rb), and that separation is exactly why the promise
    # about the records an account OWNS is shared explicitly: an administrator
    # deleting an account from the backend must erase the same export archives,
    # private analyses and chat threads the person would have erased themselves.
    # Parity of the two methods is pinned by
    # spec/models/user_erasure_path_parity_spec.rb.
    def soft_delete_and_anonymize!
      ActiveRecord::Base.transaction do
        # BEFORE the memberships, as on ::User: removing a membership unlinks
        # the person row, and erase_person_links! finds the rows by that link.
        erase_personal_data!
        memberships.destroy_all
        update_columns(
          anonymization_attributes.merge(
            deleted_at: Time.current,
            deletion_recommended: true,
            # update_columns skips the timestamp; the tenant path bumps it via
            # save!/touch, and the row-parity spec compares the two rows.
            updated_at: Time.current
          )
        )
      end
    end

    # Eager loading for admin views
    def memberships_with_details
      memberships.includes(:organisation, :role).ordered_by_organisation
    end

    def project_permissions_with_details
      project_permissions.includes(:project).joins(:project).order('projects.name')
    end

    private

    def encrypt_password_if_present
      return unless password.present?

      self.encrypted_password = ::BCrypt::Password.create(password)
    end

    # ||= rather than a plain assignment: a caller that sets its own timestamp
    # (or a record round-tripped through ::User) keeps it.
    def mark_confirmed
      self.confirmed_at ||= Time.current
    end

    # Same tombstone as ::User#anonymize!, written with update_columns because
    # this class carries no Devise: no reconfirmation swap to skip, no validation
    # to bypass. The two confirmable fields still have to be cleared here as
    # well: a pending e-mail change parks a REAL, identifying address in
    # unconfirmed_email, and an erasure that keeps it has not erased the person
    # (survived on this path until 2026-08-24; the row-parity spec pins it now).
    # Placeholder name and domain come from the one owner of those values.
    def anonymization_attributes
      {
        first_name: ::User::DeletionLifecycle::ANONYMIZED_NAME,
        last_name: ::User::DeletionLifecycle::ANONYMIZED_NAME,
        email: "deleted_user_#{SecureRandom.uuid}@#{::User::DeletionLifecycle::ANONYMIZED_EMAIL_DOMAIN}",
        encrypted_password: '',
        reset_password_token: nil,
        reset_password_sent_at: nil,
        remember_created_at: nil,
        unconfirmed_email: nil,
        confirmation_token: nil,
        contact_email: nil,
        email_visibility: 'none',
        unlock_token: nil,
        locked_at: nil,
        failed_attempts: 0
      }
    end
  end
end
