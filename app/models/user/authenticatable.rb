# frozen_string_literal: true

class User < ApplicationRecord
  # Authentication surface for User (user.rb split, slice 6/7).
  #
  # Carries the Devise registration plus the custom email, password and
  # session-timeout validations. Like slice 5 this is a behaviour Concern mixed
  # BACK INTO User, so the methods stay instance methods on User and every call
  # site keeps working unchanged with zero migration (the Devise login /
  # recovery / lock flows). Pure refactoring; behaviour is bit-identical to the
  # legacy User code this file replaces.
  #
  # timeout_in is NOT in this concern. `devise :timeoutable` mixes
  # Devise::Models::Timeoutable (which defines its own timeout_in) into User from
  # inside the `included do` below, so that module lands ABOVE this concern in
  # the ancestor chain and would shadow a concern-level override. The per-user
  # timeout_in therefore stays defined directly on the User class, where it is
  # first in the MRO and reliably wins (see the note in user.rb).
  #
  # NESTED-MODULE STYLE IS DELIBERATE, not merely a RuboCop preference. The
  # session-timeout validation in `included do` references the bareword
  # ALLOWED_SESSION_TIMEOUTS, but that constant is INTENTIONALLY kept on the User
  # class (see user.rb) because it is referenced externally as
  # User::ALLOWED_SESSION_TIMEOUTS (a view and a spec). With this nested
  # definition the lexical nesting is [User::Authenticatable, User], so the
  # bareword resolves to User::ALLOWED_SESSION_TIMEOUTS. The compact form
  # `module User::Authenticatable` would not have User in its lexical scope and
  # would break that resolution. Consequence: User must define the constant
  # BEFORE it `include`s this concern, since the validates macro reads it at
  # include time.
  #
  # SCOPE NOTE: Admin::User is a SEPARATE class (< ApplicationRecord, same users
  # table, no acts_as_tenant) with its OWN, non-soft-delete-aware email
  # validation and no Devise at all. It deliberately does NOT include this
  # concern; this concern is included ONLY in User.
  module Authenticatable
    extend ActiveSupport::Concern

    included do
      # Devise modules - skip validatable to avoid conflict with our custom validation
      #
      # :confirmable proves the address actually belongs to the registrant.
      # Without it any invented address produced a working account plus its own
      # organisation. It runs as a GRACE PERIOD (allow_unconfirmed_access_for,
      # see devise.rb), so the seeded onboarding stays reachable immediately.
      #
      # Every creation path that is NOT a self-registration bypasses the
      # confirmation mail, each handled at its own source. The address is
      # already vouched for there, and mailing a link to somebody who never
      # signed up only guarantees an account that locks itself out:
      #   - invitation signup     -> Users::RegistrationsController#build_resource
      #   - invitation acceptance -> Actors::AcceptInvitation#create_user
      #   - admin-created user    -> Admin::User (before_create; no Devise there)
      #   - codebase user import  -> ImportUsersFromCodebaseJob#create_new_user
      #   - development seeds     -> db/seeds.rb
      # Plus the system account (User.system), which never authenticates and
      # whose reserved address does not exist.
      #
      # ADDING A CREATION PATH? It belongs on this list or it needs a real
      # confirmation. The import and the seeds were missed on the first pass
      # and produced exactly that failure mode (mail to strangers, lockout on
      # day four) — grep for `User.create` before assuming the list is complete.
      devise :database_authenticatable, :registerable, :confirmable,
             :recoverable, :rememberable, :timeoutable, :lockable

      # Custom email validation to handle soft delete
      validates :email, presence: true, format: { with: Devise.email_regexp }
      validates :email, uniqueness: {
        conditions: -> { where(deleted_at: nil) },
        case_sensitive: false
      }
      validate :unique_email_among_active_users

      # Custom password validation (since we're not using validatable)
      validates :password, presence: true, length: { minimum: 6 }, if: :password_required?
      validates :password, confirmation: true, if: :password_required?

      # Per-user session timeout. ALLOWED_SESSION_TIMEOUTS lives on the User class
      # (see the comment above); the bareword resolves to it via lexical nesting.
      validates :session_timeout_minutes, inclusion: { in: ALLOWED_SESSION_TIMEOUTS }

      # A new password is how a person takes an account back, through the reset
      # link or the account form. Tokens minted by whoever held it before must
      # not outlive that. On the model so every way to a new password is covered.
      after_update :revoke_personal_access_tokens_for_new_password, if: :saved_change_to_encrypted_password?
    end

    # Drives the reminder banner (layouts/_email_confirmation): the address has
    # never been proven. A pending EMAIL CHANGE is deliberately NOT covered —
    # such an account stays confirmed under its old address and is told about
    # the open change in the account form instead of by a deadline banner.
    def awaiting_confirmation?
      !confirmed?
    end

    # Whole days left before the login is refused, or nil when the question does
    # not apply. Reads created_at because the OVERRIDDEN
    # confirmation_period_valid? (on the User class, see the comment there) does
    # — the countdown must not be able to disagree with the actual lockout, and
    # confirmation_sent_at moves on every resend.
    def confirmation_grace_days_left
      return nil if confirmed? || created_at.blank?

      deadline = created_at + self.class.allow_unconfirmed_access_for
      [((deadline - Time.current) / 1.day).ceil, 0].max
    end

    private

    def revoke_personal_access_tokens_for_new_password
      PersonalAccessToken.revoke_all_for!(self)
    end

    # Required for custom password validation
    def password_required?
      !persisted? || !password.nil? || !password_confirmation.nil?
    end

    # Custom email uniqueness validation
    def unique_email_among_active_users
      return if email.blank?

      if User.where(email: email.downcase)
             .where(deleted_at: nil)
             .where.not(id: id)
             .exists?
        errors.add(:email, :taken)
      end
    end
  end
end
