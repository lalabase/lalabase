# frozen_string_literal: true

class User < ApplicationRecord
  # === System account "Lalabase" ===
  # Pseudo user acting as the ACTOR for system-generated activities (currently:
  # onboarding seed assignments, see Actors::SeedOnboarding). The notification
  # pipeline drops the actor from the recipient set (self-actions are never
  # notified), so seeded assignments need a foreign actor to reach the new
  # user's inbox — that actor is this account.
  #
  # Fence (doc/onboarding_plan.md, decision D2):
  # - exactly one per instance, keyed by the reserved EMAIL
  # - never authenticates (locked + active_for_authentication? override)
  # - NO memberships — keeps it out of assignee pickers, team lists and
  #   policy_scopes (organisation.users goes through memberships)
  # - not deletable (guarded here AND in the tenant-bypassing Admin::User)
  # - is_ai stays false: FanoutService suppresses ALL notifications for is_ai
  #   actors, which would silently break the onboarding inbox chain
  module SystemAccount
    extend ActiveSupport::Concern

    EMAIL = 'system@lalabase.internal'

    # Shared destroy guard for BOTH model classes over the users table: User
    # (Devise, tenant-aware callbacks) and the tenant-bypassing Admin::User.
    # Admin::User deliberately shares none of User's concerns, so the fence
    # needs two REGISTRATIONS — but exactly one IMPLEMENTATION lives here.
    module DestroyFence
      extend ActiveSupport::Concern

      included do
        before_destroy :prevent_system_account_destroy
      end

      private

      def prevent_system_account_destroy
        return unless email == ::User::SystemAccount::EMAIL

        errors.add(:base, :system_account_undeletable)
        throw :abort
      end
    end

    included do
      include DestroyFence
    end

    class_methods do
      # Race-safe find-or-create: the partial unique index on email
      # (WHERE deleted_at IS NULL) turns a concurrent double-create into
      # RecordNotUnique, which we resolve by re-reading.
      def system
        find_by(email: EMAIL, deleted_at: nil) || create_system_account!
      rescue ActiveRecord::RecordNotUnique
        find_by!(email: EMAIL, deleted_at: nil)
      end

      # skip_confirmation! in the block, i.e. BEFORE the insert: :confirmable
      # would otherwise mail confirmation instructions to the reserved address
      # (a domain that does not exist) on the very first onboarding seed, and
      # bounce. The account never authenticates anyway.
      def create_system_account!
        create!(
          email: EMAIL,
          first_name: 'Lalabase',
          last_name: '',
          password: SecureRandom.hex(32),
          active: false,
          locked_at: Time.current,
          &:skip_confirmation!
        )
      end
    end

    def system_account?
      email == EMAIL
    end

    # Belt and braces on top of the Devise lock: even if someone clears
    # locked_at, the account stays unauthenticatable.
    #
    # active? is the "deactivated" switch of the admin area (users.active).
    # Devise asks this on every request, so a deactivated person is signed out
    # on the next one, and the API token check asks the same question.
    def active_for_authentication?
      super && active? && !system_account?
    end

    # The message a deactivated person sees instead of Devise's generic
    # "not activated yet". Locked and unconfirmed keep their own (super).
    def inactive_message
      return :account_deactivated unless active? || system_account?

      super
    end
  end
end
