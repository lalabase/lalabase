# frozen_string_literal: true

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

# =============================================================================
# User Factory for Testing
# =============================================================================
# Factory for creating User instances in tests with sensible defaults.
# Includes traits for testing different user states and relationships.
# =============================================================================

FactoryBot.define do
  factory :user do
    # Basic user attributes with sensible defaults
    sequence(:email) { |n| "user#{n}@example.com" }
    password { 'password123' }
    first_name { 'Test' }
    last_name { 'User' }
    is_ai { false }
    active { true } # Users are active by default (matches database default)

    # Confirmed by default (:confirmable, registration hardening). Without it
    # every factory user would be a fresh UNCONFIRMED account whose access
    # merely happens to fall inside the grace period — the whole suite would
    # then silently depend on allow_unconfirmed_access_for, and shortening that
    # window later would turn hundreds of unrelated specs red for no reason.
    # Specs about the confirmation flow itself use the traits below.
    confirmed_at { Time.current }

    # A brand-new self-registered account: still inside the grace period, so it
    # can sign in, but the address is unproven.
    trait :unconfirmed do
      confirmed_at { nil }
      confirmation_sent_at { Time.current }
    end

    # Grace period elapsed — Devise refuses the login from here on.
    #
    # Ages the record AFTER creation, with update_columns: :confirmable sends
    # its mail from an after_create callback and stamps confirmation_sent_at to
    # Time.current in the process, so any value set as an attribute here is
    # silently overwritten and the account would still be inside the window.
    trait :confirmation_overdue do
      confirmed_at { nil }

      after(:create) do |user|
        overdue = (User.allow_unconfirmed_access_for + 1.day).ago
        user.update_columns(confirmation_sent_at: overdue, created_at: overdue)
      end
    end

    # Ensure email uniqueness across test runs
    # Prepends timestamp to handle rapid test execution where sequence might repeat
    # Only applies when email is not explicitly set to avoid interference with uniqueness tests
    after(:build) do |user|
      user.email = "#{Time.current.to_i}#{user.email}" if user.email.match?(/^user\d+@example\.com$/) && User.where(email: user.email).where(deleted_at: nil).exists?
    end

    # ==========================================================================
    # Accept inline organisation attribute to auto-create membership
    # ==========================================================================
    transient do
      organisation { nil }
    end

    after(:create) do |user, evaluator|
      if evaluator.organisation.present?
        ActsAsTenant.with_tenant(evaluator.organisation) do
          create(:membership, user: user, organisation: evaluator.organisation, active: true)
        end
      end
    end

    # ==========================================================================
    # Test Traits for Different User States
    # ==========================================================================

    # Creates user with organization membership (for multi-tenant scenarios)
    trait :with_organisation do
      after(:create) do |user, _evaluator|
        organisation = create(:organisation)
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: user, organisation: organisation, active: true)
        end
      end
    end

    # Creates inactive user (for testing user status functionality)
    trait :inactive do
      active { false }
    end

    # Explicitly creates active user (redundant but explicit for test clarity)
    trait :active do
      active { true }
    end

    # Creates user with soft delete attributes for testing deletion functionality
    trait :soft_deleted do
      deleted_at { 1.day.ago }
      deletion_recommended { false }
    end

    # Creates user recommended for deletion
    trait :recommended_for_deletion do
      deletion_recommended { true }
    end

    # Creates user with invite tracking information
    trait :invited do
      association :invited_by_user, factory: :user
      association :invited_by_org, factory: :organisation
    end

    # Creates anonymized user (as would appear after deletion)
    trait :anonymized do
      first_name { 'Anonym' }
      last_name { 'Anonym' }
      sequence(:email) { |_n| "anonym_#{SecureRandom.hex(8)}@deleted.local" }
      deleted_at { 1.day.ago }
    end

    # Creates admin user (for admin-specific functionality testing)
    trait :admin do
      # Admin trait for testing admin-specific functionality
      # Note: This is a placeholder trait for compatibility with tests
      # Actual admin status may be determined by role/permissions in organisation
    end
  end
end
