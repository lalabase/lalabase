# frozen_string_literal: true

class User < ApplicationRecord
  # Account-deletion / GDPR-anonymisation lifecycle for User (user.rb split,
  # slice 5/7).
  #
  # Unlike slices 1-4 (which moved JSONB-backed preference helpers into POROs),
  # these methods operate on dedicated COLUMNS (deleted_at, scheduled_deletion_at,
  # deletion_reason, deletion_canceled_at, deletion_recommended) and stay
  # INSTANCE METHODS on User via this concern. That is the whole point of the
  # slice: every call site keeps working unchanged with zero migration —
  # current_user.anonymize!, ScheduledDeletionJob#execute_scheduled_deletion,
  # DeleteAccountService, CancelAccountDeletionsController. Pure refactoring; the
  # behaviour is bit-identical to the legacy User methods this file replaces.
  #
  # Relies on the including class (User) providing:
  #   - soft_delete! / deleted?      (SoftDeletable)
  #   - memberships / active_memberships
  #   - the SystemSetting and Beuser constants
  # Method resolution happens at call time, so the include position among User's
  # other includes is irrelevant.
  #
  # track_deletion_canceled is intentionally called behind a respond_to? guard:
  # the hook does not exist on User in the app today, so the guard is what keeps
  # cancel_scheduled_deletion! from raising NoMethodError.
  #
  # SCOPE NOTE: Admin::User is a SEPARATE class (< ApplicationRecord, same users
  # table, no acts_as_tenant) that keeps its OWN copies of several of these
  # methods — partly with different signatures (e.g. can_be_deleted_by?(requester,
  # source = nil)). Those copies are deliberately NOT unified into this concern
  # and Admin::User does NOT include it; the admin backend is intentionally
  # separate. This concern is included ONLY in User.
  module DeletionLifecycle
    extend ActiveSupport::Concern

    # The ONE exception to the paragraph above, and a deliberate one: erasing the
    # personal records an account owns (export archives, private analyses, own
    # chat threads) is shared with Admin::User through a separate, single-purpose
    # concern. Not because the admin backend stops being separate, but because
    # this particular promise must not be kept on only one of the two paths.
    # Parity of the two methods is pinned by
    # spec/models/user_erasure_path_parity_spec.rb.
    included do
      include PersonalDataErasure
    end

    # Placeholder written over first/last name on anonymisation.
    ANONYMIZED_NAME = 'Anonym'
    # Non-routable sentinel domain for the scrambled placeholder email. It marks
    # the address as belonging to a deleted account and can never receive mail.
    ANONYMIZED_EMAIL_DOMAIN = 'deleted.local'

    # GDPR anonymisation: overwrite every identifying field on the row in place.
    # The values are deliberate "tombstones":
    #   - the name becomes a fixed placeholder (ANONYMIZED_NAME);
    #   - the email becomes a unique, non-routable address so it can neither
    #     collide with the partial unique index on active emails nor receive mail;
    #   - all credential/recovery fields are blanked so the dead account can
    #     never be logged into or password-reset.
    #
    # save!(validate: false) is REQUIRED, not laziness: the anonymised state
    # (blank encrypted_password, plus any data that was already invalid on the
    # row) would otherwise trip model validations, and a GDPR erasure must never
    # be blocked by validation. Do NOT "tidy" this into a validating save!.
    #
    # skip_reconfirmation! is equally load-bearing since :confirmable arrived:
    # reconfirmable treats this as an ordinary e-mail change, i.e. it parks the
    # tombstone address in unconfirmed_email, RESTORES the real address on the
    # row and mails confirmation instructions to @deleted.local. An erasure that
    # keeps the identifying address and sends mail about it is the exact
    # opposite of the job (caught by deletion_lifecycle_spec).
    #
    # unconfirmed_email must be CLEARED on top of that, not just left alone:
    # skip_reconfirmation! only stops the swap, it does not empty a field that
    # a pending e-mail change already filled. Someone who changes their address
    # and requests deletion before clicking the link would otherwise leave a
    # real, identifying address on the erased row — which is exactly what the
    # first line of this comment promises never happens.
    def anonymize!
      self.first_name = ANONYMIZED_NAME
      self.last_name = ANONYMIZED_NAME
      self.email = "anonym_#{SecureRandom.hex(8)}@#{ANONYMIZED_EMAIL_DOMAIN}"
      self.encrypted_password = ''
      self.reset_password_token = nil
      self.reset_password_sent_at = nil
      self.remember_created_at = nil
      self.unconfirmed_email = nil
      self.confirmation_token = nil
      # :lockable belongs to the "credential/recovery fields" promised blank
      # above; a live unlock token on an erased row is a credential like any
      # other (survived both paths until 2026-08-24).
      self.unlock_token = nil
      self.locked_at = nil
      self.failed_attempts = 0
      skip_reconfirmation!
      # without_activity_tracking: this save would otherwise fire
      # UserTrackable#track_email_change and store the REAL address in
      # user_activities.metadata (old_email) at the very moment of its erasure.
      without_activity_tracking { save!(validate: false) }
    end

    # Schedule account deletion with grace period
    def schedule_deletion!(reason: nil)
      grace_period_days = SystemSetting.account_deletion_grace_period_days

      if grace_period_days.zero?
        # Immediate deletion, no grace period
        soft_delete_and_anonymize!
      else
        # Schedule deletion for future
        update!(
          scheduled_deletion_at: grace_period_days.days.from_now,
          deletion_reason: reason
        )
      end
    end

    # Cancel scheduled deletion
    def cancel_scheduled_deletion!(reason: nil)
      return false unless deletion_scheduled?

      update!(
        scheduled_deletion_at: nil,
        deletion_canceled_at: Time.current,
        deletion_reason: nil
      )

      # track_deletion_canceled is an OPTIONAL audit hook. It is not defined
      # anywhere on User today (both call sites in the app guard it exactly like
      # this), so the respond_to? guard is load-bearing, not boilerplate:
      # calling it unconditionally would raise NoMethodError on a normal user and
      # break every cancellation. Keep the guard unless/until the hook becomes a
      # guaranteed method on User.
      track_deletion_canceled(reason: reason) if respond_to?(:track_deletion_canceled)
      true
    end

    # Check if deletion is scheduled
    def deletion_scheduled?
      scheduled_deletion_at.present? && scheduled_deletion_at > Time.current
    end

    # Days remaining until deletion
    def days_until_deletion
      return nil unless deletion_scheduled?

      ((scheduled_deletion_at - Time.current) / 1.day).ceil
    end

    # Hard cut for a confirmed deletion: drop the user's org memberships (revokes
    # all access), flag the account, scramble the data and soft-delete the row.
    # Wrapped in a transaction on purpose — these four steps must be
    # all-or-nothing. A partial failure (e.g. anonymised but not soft-deleted, or
    # memberships gone while the account is still active) would leave an
    # inconsistent, half-erased user that no later run can cleanly recover.
    def soft_delete_and_anonymize!
      transaction do
        memberships.destroy_all
        # Export archives, private analyses, own chat threads: shared with
        # Admin::User through PersonalDataErasure (see there for why each step is
        # explicit).
        erase_personal_data!
        # update_column, not update!: this row is about to be force-saved past
        # validations by anonymize! (an erasure must never be blocked by
        # validation), so validating here would let a legacy-invalid row abort
        # the erasure one line before the bypass.
        update_column(:deletion_recommended, true)
        anonymize!
        soft_delete!
      end
    end

    # Check if account can be deleted by the requester
    def can_be_deleted_by?(requester, source)
      case source
      when 'selfservice'
        # Users can only delete their own account
        requester == self
      when 'backend'
        # Any Beuser can delete any account
        requester.is_a?(Beuser)
      else
        false
      end
    end

    # Mark user for deletion recommendation (when all memberships removed)
    def mark_for_deletion_review!
      update!(deletion_recommended: true) unless deleted?
    end

    # Check if user should be recommended for deletion
    def should_be_recommended_for_deletion?
      !deleted? && active_memberships.count.zero?
    end
  end
end
