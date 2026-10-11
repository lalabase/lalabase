# frozen_string_literal: true

require 'rails_helper'

# Specs for User::DeletionLifecycle — the account-deletion / GDPR-anonymisation
# methods extracted from the User god-class (user.rb split, slice 5/7).
#
# WHAT THIS GUARDS
# Slices 1-4 moved JSONB-backed preference helpers into POROs. This slice is
# structurally different: it extracts COLUMN-backed lifecycle methods
# (deleted_at, scheduled_deletion_at, deletion_reason, deletion_canceled_at,
# deletion_recommended) into a Concern that is mixed BACK INTO User. The methods
# stay instance methods on User, so every call site keeps working unchanged
# (current_user.anonymize!, ScheduledDeletionJob#execute_scheduled_deletion,
# DeleteAccountService, CancelAccountDeletionsController). The slice is a pure
# refactoring: behaviour must stay bit-identical to the legacy User methods.
# Most examples here are CHARACTERIZATION tests — they pin what the app already
# does, not new requirements. Read them as "this is what the app already does
# and must keep doing".
#
# NOTE ON SCOPE: Admin::User is a SEPARATE class (< ApplicationRecord, same
# users table, no acts_as_tenant) with its OWN copies of several of these
# methods (partly different signatures). Those copies are deliberately NOT
# unified into this concern and are NOT covered here — Admin::User has its own
# spec. This file only pins the User-side behaviour.
#
# WHY THE EXAMPLES LOOK THE WAY THEY DO (mutation-resistance)
# Each non-obvious example is written so that a plausible one-line code change
# (a "mutant") reddens a specific example. Patterns that can look redundant:
#   - anonymize! is asserted to bypass validation (save!(validate: false)) by
#     anonymising a record that a validating save! would reject — flipping to a
#     validating save! reddens it;
#   - soft_delete_and_anonymize! has an atomicity example that forces the final
#     step to raise and asserts NO partial state survives — dropping the
#     transaction reddens it;
#   - schedule_deletion! pins BOTH grace-period branches (0 => immediate delete,
#     >0 => only schedule) — inverting the `.zero?` test reddens one of them;
#   - deletion_scheduled? / days_until_deletion are tested with time frozen at a
#     fixed, sub-second-zero instant. Two reasons: the boundary is strict
#     (`> now`, `.ceil`) and only an exact equality kills the `>`-vs-`>=` and
#     `.ceil`-vs-`.floor` mutants; and the VM clock can drift, so no time
#     comparison here is ever left un-frozen (project caveat);
#   - cancel_scheduled_deletion! asserts BOTH return values (false when nothing
#     is scheduled, true otherwise) AND that the defensive respond_to? guard
#     around track_deletion_canceled is preserved. That hook does not exist on
#     User in the app, so removing the guard turns the plain-user "returns true"
#     example into a NoMethodError.
# Each such example states, in its own comment, which mutant it kills.
#
# Why this file describes `User` and not `User::DeletionLifecycle`: the methods
# are mixed back into User and are always invoked on User instances. Describing
# User keeps this spec loadable and green across the whole refactoring sequence
# (it predates the concern file by one commit) and means no spec change is
# needed when the concern is finally extracted.
RSpec.describe User, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  # A fixed instant with zero sub-seconds. Travelling here makes DB round-trip
  # truncation (microseconds) a no-op, so exact-boundary equality assertions on
  # datetime columns are deterministic instead of flaky-by-nanoseconds.
  let(:frozen_instant) { Time.utc(2030, 1, 1, 12, 0, 0) }

  describe '#anonymize!' do
    let(:user) { create(:user) }

    it 'anonymizes user data' do
      user.update!(
        first_name: 'John',
        last_name: 'Doe',
        email: 'john.doe@example.com'
      )

      user.anonymize!
      user.reload

      expect(user.first_name).to eq('Anonym')
      expect(user.last_name).to eq('Anonym')
      expect(user.email).to match(/anonym_\w+@deleted\.local/)
    end

    it 'preserves non-personal data' do
      original_id = user.id
      original_created_at = user.created_at

      user.anonymize!
      user.reload

      expect(user.id).to eq(original_id)
      expect(user.created_at).to eq(original_created_at)
    end

    it 'clears the credential / recovery fields' do
      # anonymize! must scrub the auth surface, not just the name/email. The
      # factory user already has an encrypted_password (asserted present below);
      # we add the recovery columns through a validating update! so the setup
      # exercises no validation-skipping shortcut.
      user.update!(
        reset_password_token: 'tok',
        reset_password_sent_at: Time.current,
        remember_created_at: Time.current
      )
      expect(user.encrypted_password).to be_present

      user.anonymize!
      user.reload

      expect(user.encrypted_password).to eq('')
      expect(user.reset_password_token).to be_nil
      expect(user.reset_password_sent_at).to be_nil
      expect(user.remember_created_at).to be_nil
    end

    # An address change parks the NEW address in unconfirmed_email until the
    # link is clicked. Requesting deletion in that window used to leave a real,
    # identifying address on the erased row: skip_reconfirmation! stops the
    # swap, it does not empty a field that is already filled.
    it 'clears an e-mail change that was still awaiting confirmation' do
      user.update!(email: 'neue.adresse@firma.example')
      expect(user.reload.unconfirmed_email).to eq('neue.adresse@firma.example')

      user.anonymize!
      user.reload

      expect(user.unconfirmed_email).to be_nil
      expect(user.confirmation_token).to be_nil
      expect(user.email).to match(/\Aanonym_\h+@deleted\.local\z/)
    end

    it 'disables authentication for the dead account (the WHY behind blanking encrypted_password)' do
      # Checking the column value (== '') is not enough — what matters is the
      # CONSEQUENCE: a deleted account must no longer be loginnable. The factory
      # user signs in with 'password123' (sanity precondition), and after
      # anonymisation no password may authenticate.
      # Mutant kill: dropping `self.encrypted_password = ''` keeps the bcrypt
      # digest and valid_password?('password123') stays true here.
      expect(user.valid_password?('password123')).to be true

      user.anonymize!

      expect(user.valid_password?('password123')).to be false
      expect(user.valid_password?('')).to be false
    end

    it 'gives each anonymised account a distinct, non-routable email' do
      # The scrambled email is randomised on purpose: the partial unique index
      # index_users_on_email_active forbids two ACTIVE rows sharing an email, and
      # anonymize! does NOT soft-delete, so the row stays active. A fixed
      # placeholder would collide on the second account.
      # Mutant kill: removing SecureRandom.hex makes these two emails equal (and
      # the second save raise on the unique index).
      other = create(:user)

      # Both saves succeeding (no RecordNotUnique on the active-email index) plus
      # the distinct in-memory values prove the address is randomised per call.
      user.anonymize!
      other.anonymize!

      expect(user.email).not_to eq(other.email)
      expect(user.email).to match(/\Aanonym_\h+@deleted\.local\z/)
    end

    it 'persists even when the record is otherwise invalid (save!(validate: false))' do
      # A deletion must never be blocked by stale, unrelated invalid data.
      # language_preference is intentionally not touched by anonymize!, so an
      # out-of-range value here would make a *validating* save raise.
      # Mutant kill: save!(validate: false) -> save! turns this into an
      # ActiveRecord::RecordInvalid.
      user.language_preference = 'klingon' # not in %w[de en]

      expect { user.anonymize! }.not_to raise_error
      expect(user.reload.first_name).to eq('Anonym')
    end
  end

  describe '#soft_delete_and_anonymize!' do
    let(:user) { create(:user) }

    it 'soft deletes and anonymizes the user' do
      original_email = user.email

      user.soft_delete_and_anonymize!
      user.reload

      expect(user.deleted_at).to be_present
      expect(user.email).not_to eq(original_email)
      expect(user.email).to match(/anonym_\w+@deleted\.local/)
    end

    it 'persists changes to database' do
      user.soft_delete_and_anonymize!

      reloaded_user = described_class.with_deleted.find(user.id)
      expect(reloaded_user.deleted_at).to be_present
      expect(reloaded_user.first_name).to eq('Anonym')
    end

    context 'full contract (with a membership present)' do
      let(:organisation) { create(:organisation) }

      before do
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: user, organisation: organisation, active: true)
        end
      end

      it 'soft-deletes, anonymises, drops memberships and flags deletion_recommended' do
        user.soft_delete_and_anonymize!
        user.reload

        expect(user).to be_deleted
        expect(user.first_name).to eq('Anonym')
        expect(user.email).to match(/anonym_\w+@deleted\.local/)
        expect(user.deletion_recommended).to be true
        expect(user.memberships).to be_empty
      end

      it 'is atomic: a raise in the final step rolls back every earlier step' do
        # Force the LAST step (soft_delete!) to blow up. Because the method body
        # runs inside a transaction, none of memberships.destroy_all /
        # deletion_recommended / anonymize! may survive.
        # Mutant kill: removing the `transaction do ... end` wrapper leaves a
        # partial state (anonymised + memberships gone but not soft-deleted) and
        # reddens every assertion below.
        allow(user).to receive(:soft_delete!).and_raise(StandardError, 'boom')

        expect { user.soft_delete_and_anonymize! }.to raise_error(StandardError, 'boom')
        user.reload

        expect(user.deleted_at).to be_nil
        expect(user.deletion_recommended).to be false
        expect(user.first_name).not_to eq('Anonym')
        expect(user.memberships.count).to eq(1)
      end
    end

    context 'multi-org cleanup and cross-user isolation' do
      it 'drops every membership the user has across all orgs but leaves other users untouched' do
        # memberships.destroy_all runs through the user's association — it must
        # clear ALL of this user's memberships (User is not tenant-scoped, so a
        # user can belong to several orgs) and must NOT touch anyone else.
        # Mutant kill: an org-scoped or globally-scoped destroy would either
        # leave one membership behind or wipe the bystander's.
        org_a = create(:organisation)
        org_b = create(:organisation)
        bystander = create(:user)
        ActsAsTenant.with_tenant(org_a) do
          create(:membership, user: user, organisation: org_a, active: true)
        end
        ActsAsTenant.with_tenant(org_b) do
          create(:membership, user: user, organisation: org_b, active: true)
        end
        ActsAsTenant.with_tenant(org_a) do
          create(:membership, user: bystander, organisation: org_a, active: true)
        end

        expect { user.soft_delete_and_anonymize! }
          .to change { user.memberships.count }.from(2).to(0)

        expect(bystander.reload.memberships.count).to eq(1)
      end
    end
  end

  describe '#schedule_deletion!' do
    let(:user) { create(:user) }

    context 'when the grace period is zero (immediate deletion)' do
      let(:organisation) { create(:organisation) }

      before do
        allow(SystemSetting).to receive(:account_deletion_grace_period_days).and_return(0)
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: user, organisation: organisation, active: true)
        end
      end

      it 'runs the FULL deletion immediately (delegates to soft_delete_and_anonymize!)' do
        # Mutant kill 1: inverting `grace_period_days.zero?` takes the "schedule
        # for later" branch and leaves the user un-deleted (be_deleted reddens).
        # Mutant kill 2: calling a partial path (e.g. anonymize! only) instead of
        # soft_delete_and_anonymize! would skip membership cleanup and the
        # deletion_recommended flag — both asserted here, so the zero-branch is
        # pinned to the full delegation, not just "scrambles the name".
        user.schedule_deletion!(reason: 'gdpr request')
        user.reload

        expect(user).to be_deleted
        expect(user.first_name).to eq('Anonym')
        expect(user.scheduled_deletion_at).to be_nil
        expect(user.deletion_recommended).to be true
        expect(user.memberships).to be_empty
      end
    end

    context 'when the grace period is positive (deferred deletion)' do
      before { allow(SystemSetting).to receive(:account_deletion_grace_period_days).and_return(30) }

      it 'schedules the deletion for the future without deleting yet' do
        # Mutant kill: inverting `.zero?` would soft-delete immediately and this
        # "not deleted, only scheduled" assertion would redden.
        travel_to(frozen_instant) do
          user.schedule_deletion!(reason: 'changed mind maybe')
          user.reload

          expect(user.deleted_at).to be_nil
          expect(user.first_name).not_to eq('Anonym')
          expect(user.scheduled_deletion_at).to eq(30.days.from_now)
          expect(user.deletion_reason).to eq('changed mind maybe')
        end
      end
    end
  end

  describe '#cancel_scheduled_deletion!' do
    let(:user) { create(:user) }

    context 'when no deletion is scheduled' do
      it 'returns false and changes nothing' do
        # Mutant kill: a swallowed/omitted `return false` reddens this; pairing
        # the return value with a "no scheduled deletion" state pins the guard.
        expect(user.cancel_scheduled_deletion!).to be false
      end
    end

    context 'when a deletion is scheduled' do
      it 'clears the schedule, stamps deletion_canceled_at and returns true' do
        # This example also pins the respond_to? guard: this user has NO
        # track_deletion_canceled hook, so removing the guard (a direct call)
        # raises NoMethodError and this "returns true" example reddens.
        # Schedule and cancel both happen inside the frozen instant so the
        # scheduled time stays in the future relative to "now".
        travel_to(frozen_instant) do
          user.update!(scheduled_deletion_at: 30.days.from_now, deletion_reason: 'oops')

          result = user.cancel_scheduled_deletion!(reason: 'staying')

          expect(result).to be true
          user.reload
          expect(user.scheduled_deletion_at).to be_nil
          expect(user.deletion_reason).to be_nil
          expect(user.deletion_canceled_at).to eq(Time.current)
        end
      end

      it 'forwards the reason to track_deletion_canceled when the hook exists (positive side of the guard)' do
        # The hook is absent on User in the app (verify_partial_doubles forbids
        # stubbing a non-existent method), so we add a REAL singleton method to
        # this one instance. With it present, the respond_to? guard lets the
        # call through and forwards the reason.
        user.update!(scheduled_deletion_at: 30.days.from_now, deletion_reason: 'oops')
        forwarded = :not_called
        user.define_singleton_method(:track_deletion_canceled) { |reason:| forwarded = reason }

        expect(user.cancel_scheduled_deletion!(reason: 'staying')).to be true
        expect(forwarded).to eq('staying')
      end
    end

    context 'lifecycle round-trip (schedule -> cancel -> reschedule)' do
      before { allow(SystemSetting).to receive(:account_deletion_grace_period_days).and_return(30) }

      it 'can be re-scheduled after a cancellation and keeps the cancellation audit stamp' do
        # A real user journey: request deletion, change your mind, then change it
        # back. Re-scheduling must work AND must not erase deletion_canceled_at —
        # that timestamp is the audit trail of the earlier cancellation.
        # Mutant kill: a schedule_deletion! that cleared deletion_canceled_at
        # would redden the final eq(canceled_at).
        travel_to(frozen_instant) do
          user.schedule_deletion!(reason: 'first try')
          expect(user.deletion_scheduled?).to be true

          user.cancel_scheduled_deletion!(reason: 'wait')
          user.reload
          expect(user.deletion_scheduled?).to be false
          canceled_at = user.deletion_canceled_at
          expect(canceled_at).to be_present

          user.schedule_deletion!(reason: 'really this time')
          user.reload
          expect(user.deletion_scheduled?).to be true
          expect(user.deletion_reason).to eq('really this time')
          expect(user.deletion_canceled_at).to eq(canceled_at)
        end
      end
    end
  end

  describe '#deletion_scheduled?' do
    let(:user) { create(:user) }

    it 'is false when nothing is scheduled' do
      expect(user.deletion_scheduled?).to be false
    end

    it 'is true when scheduled strictly in the future' do
      travel_to(frozen_instant) do
        user.scheduled_deletion_at = 1.second.from_now
        expect(user.deletion_scheduled?).to be true
      end
    end

    it 'is false at the exact boundary (strictly greater than now)' do
      # Mutant kill: `> Time.current` -> `>= Time.current` makes "exactly now"
      # count as scheduled. The fixed sub-second-zero instant guarantees the
      # in-memory value equals Time.current exactly, so only the strict
      # comparison keeps this false.
      travel_to(frozen_instant) do
        user.scheduled_deletion_at = Time.current
        expect(user.deletion_scheduled?).to be false
      end
    end

    it 'is false when the scheduled time already passed' do
      travel_to(frozen_instant) do
        user.scheduled_deletion_at = 1.second.ago
        expect(user.deletion_scheduled?).to be false
      end
    end
  end

  describe '#days_until_deletion' do
    let(:user) { create(:user) }

    it 'is nil when nothing is scheduled' do
      expect(user.days_until_deletion).to be_nil
    end

    it 'is nil when the scheduled time is in the past (deletion not scheduled)' do
      travel_to(frozen_instant) do
        user.scheduled_deletion_at = 1.day.ago
        expect(user.days_until_deletion).to be_nil
      end
    end

    it 'rounds a partial remaining day UP (.ceil)' do
      # 2 days + 1 hour remaining -> 3 whole days.
      # Mutant kill: .ceil -> .floor (or .round) returns 2 here.
      travel_to(frozen_instant) do
        user.scheduled_deletion_at = Time.current + 2.days + 1.hour
        expect(user.days_until_deletion).to eq(3)
      end
    end

    it 'rounds a sub-day remainder up to 1, never 0 (user-facing banner boundary)' do
      # With only 1 hour left the warning banner must still read "1 day", never
      # "0" (which would read as "already gone / today").
      # Mutant kill: .ceil -> .to_i / .floor returns 0 here — the most
      # user-visible off-by-one in this method.
      travel_to(frozen_instant) do
        user.scheduled_deletion_at = Time.current + 1.hour
        expect(user.days_until_deletion).to eq(1)
      end
    end

    it 'returns the whole number of days for an exact multiple' do
      travel_to(frozen_instant) do
        user.scheduled_deletion_at = Time.current + 5.days
        expect(user.days_until_deletion).to eq(5)
      end
    end
  end

  describe '#can_be_deleted_by?' do
    let(:admin_user) { create(:user) }
    let(:other_user) { create(:user) }
    let(:beuser) { create(:beuser) }
    let(:user) { create(:user) }
    let(:organisation) { create(:organisation) }

    before do
      ActsAsTenant.with_tenant(organisation) do
        admin_role = organisation.find_or_create_account_admin_role
        create(:membership, user: admin_user, organisation: organisation, role: admin_role, active: true)
        create(:membership, user: user, organisation: organisation, active: true)
      end
    end

    context 'self-deletion' do
      it 'allows users to delete themselves' do
        expect(user.can_be_deleted_by?(user, 'selfservice')).to be true
      end
    end

    context 'backend deletion by beuser' do
      it 'allows any beuser to delete any user' do
        expect(user.can_be_deleted_by?(beuser, 'backend')).to be true
      end
    end

    context 'admin deletion within organisation' do
      it 'does not allow admin users to delete other users directly' do
        expect(user.can_be_deleted_by?(admin_user, 'selfservice')).to be false
      end
    end

    context 'regular user attempting to delete another user' do
      it 'does not allow regular users to delete other users' do
        expect(user.can_be_deleted_by?(other_user, 'selfservice')).to be false
      end
    end

    context 'backend deletion by a non-beuser' do
      it 'does not allow a regular user to delete via the backend source' do
        # Mutant kill: `requester.is_a?(Beuser)` -> `true` would wrongly allow
        # any requester through the backend branch.
        expect(user.can_be_deleted_by?(other_user, 'backend')).to be false
      end
    end

    context 'unrecognised source' do
      it 'denies any source that is neither selfservice nor backend' do
        # Mutant kill: a missing `else false` (or a fall-through) would let an
        # unknown source authorise deletion.
        expect(user.can_be_deleted_by?(user, 'admin')).to be false
        expect(user.can_be_deleted_by?(beuser, 'whatever')).to be false
      end
    end

    context 'cross-combinations of requester and source (the two branches are independent)' do
      it 'denies self-deletion through the backend source — identity is not enough, it needs a Beuser' do
        # Pins that the backend branch checks TYPE only. Mutant kill: a backend
        # branch that also accepted `requester == self` would allow this.
        expect(user.can_be_deleted_by?(user, 'backend')).to be false
      end

      it 'denies a beuser through the selfservice source — type is not enough, it needs identity' do
        # Pins that the selfservice branch checks IDENTITY only. Mutant kill: a
        # selfservice branch that also accepted Beusers would allow this.
        expect(user.can_be_deleted_by?(beuser, 'selfservice')).to be false
      end

      it 'rejects a Symbol source (the contract is string-only)' do
        # Callers pass String sources (DeleteAccountService whitelists
        # %w[selfservice backend]); a Symbol must fall through case/=== to false.
        expect(user.can_be_deleted_by?(user, :selfservice)).to be false
      end
    end
  end

  describe '#should_be_recommended_for_deletion?' do
    let(:user) { create(:user) }
    let(:organisation) { create(:organisation) }

    context 'when user has active memberships' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: user, organisation: organisation, active: true)
        end
      end

      it 'returns false' do
        expect(user.should_be_recommended_for_deletion?).to be false
      end
    end

    context 'when user has no active memberships' do
      it 'returns true' do
        expect(user.should_be_recommended_for_deletion?).to be true
      end
    end

    context 'when user has only inactive memberships' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: user, organisation: organisation, active: false)
        end
      end

      it 'returns true' do
        expect(user.should_be_recommended_for_deletion?).to be true
      end
    end

    context 'when the user is already soft-deleted' do
      it 'returns false even with no active memberships' do
        # Mutant kill: dropping the `!deleted?` guard returns true here (the user
        # has zero active memberships) — a soft-deleted user must never be
        # re-recommended.
        user.soft_delete!
        expect(user.should_be_recommended_for_deletion?).to be false
      end
    end

    context 'when active in one org but inactive in another (cross-org aggregation)' do
      before do
        org_active = create(:organisation)
        org_inactive = create(:organisation)
        ActsAsTenant.with_tenant(org_active) do
          create(:membership, user: user, organisation: org_active, active: true)
        end
        ActsAsTenant.with_tenant(org_inactive) do
          create(:membership, user: user, organisation: org_inactive, active: false)
        end
      end

      it 'returns false — a single active membership in ANY org protects the user' do
        # active_memberships.count aggregates across all orgs (User is not
        # tenant-scoped). Mutant kill: scoping to one org, using .first, or an
        # off-by-one in the zero-check would wrongly recommend a still-active user.
        expect(user.should_be_recommended_for_deletion?).to be false
      end
    end
  end

  describe '#mark_for_deletion_review!' do
    let(:user) { create(:user) }

    it 'sets deletion_recommended to true' do
      expect { user.mark_for_deletion_review! }
        .to change { user.reload.deletion_recommended }
        .from(false).to(true)
    end

    it 'persists the change' do
      user.mark_for_deletion_review!
      expect(user.reload.deletion_recommended).to be true
    end

    it 'does not touch a soft-deleted user (unless deleted? guard)' do
      # Mutant kill: dropping the `unless deleted?` guard would flip the flag on
      # an already-deleted user.
      user.soft_delete!

      expect { user.mark_for_deletion_review! }
        .not_to change { user.reload.deletion_recommended }.from(false)
    end
  end
end
