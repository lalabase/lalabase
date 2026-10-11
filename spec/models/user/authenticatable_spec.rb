# frozen_string_literal: true

require 'rails_helper'

# Specs for the authentication surface of User — the Devise registration and the
# custom email/password/session-timeout validations extracted into
# User::Authenticatable (user.rb split, slice 6/7), plus the per-user
# `timeout_in` override which deliberately stays on the User class (it must
# override Devise::Models::Timeoutable, which `devise :timeoutable` mixes in
# above the concern in the ancestor chain — a concern-level method would be
# shadowed).
#
# WHAT THIS GUARDS
# Slices 1-4 moved JSONB-backed preference helpers into POROs; slice 5 moved
# column-backed lifecycle methods into a Concern. This slice is structurally
# like slice 5 — a Concern mixed BACK INTO User, so the behaviour stays on User
# and every call site keeps working unchanged with zero migration. The risk of
# this particular move is narrow but high-stakes: it must keep the Devise
# module registration, the custom validations and the constant resolution
# intact. Most examples here are CHARACTERIZATION tests — they pin what the app
# already does, not new requirements. They are deliberately written to keep
# passing identically whether the code lives on User or in the Concern, so the
# same file proves "no behaviour changed" across the extraction commit.
#
# CONTRACTS PINNED HERE
#   - Devise.mappings[:user] keeps all six modules (the devise() macro ran).
#   - email: presence + format + soft-delete-aware uniqueness (both directions
#     of unique_email_among_active_users).
#   - password: custom validation (we do NOT use :validatable) — presence +
#     minimum length of 6 + confirmation, gated by password_required?.
#   - password_required? gating: always on a new record; off when a persisted
#     record is updated without touching the password; on again the moment a
#     password is set on a persisted record.
#   - User::ALLOWED_SESSION_TIMEOUTS stays resolvable AS A USER CONSTANT (it is
#     referenced externally as User::ALLOWED_SESSION_TIMEOUTS) and the
#     session_timeout_minutes inclusion validation honours exactly that list.
#   - timeout_in returns the per-user value and overrides Devise's global one.
#
# WHY THE DEVISE-LIFECYCLE EXAMPLES ARE INTEGRATION, NOT UNIT
# The real risk of the extraction is whether `devise ...` inside the Concern's
# `included do` still wires the modules into User. Stubbing would hide exactly
# that failure mode, so the lifecycle examples drive the REAL Devise code paths
# on REAL records (valid_password?, send_reset_password_instructions /
# reset_password_by_token, the failed-attempts lock flow, remember_me!,
# timedout?) with no doubles. If the macro silently dropped a module the method
# would vanish and the example would error.
RSpec.describe User, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  # Proves the devise() macro actually ran and registered every module. A move
  # that dropped the macro (or a single module) reddens this immediately, before
  # any behavioural example even loads.
  describe 'Devise module registration' do
    it 'keeps all six Devise modules on the :user mapping' do
      mapping = Devise.mappings[:user]
      expect(mapping).to be_present
      expect(mapping.modules).to include(
        :database_authenticatable, :registerable, :recoverable,
        :rememberable, :timeoutable, :lockable
      )
    end

    # The code deliberately skips :validatable ("to avoid conflict with our custom
    # validation") — enabling it would impose Devise's own email format + the
    # config.password_length (12..128) rules and break the custom 6-char minimum.
    # Pin that decision directly so re-adding :validatable reddens here.
    it 'deliberately does NOT enable :validatable' do
      expect(Devise.mappings[:user].modules).not_to include(:validatable)
    end
  end

  describe 'email validation' do
    it { is_expected.to validate_presence_of(:email) }
    it { is_expected.to validate_uniqueness_of(:email).case_insensitive }
    it { is_expected.to allow_value('user@example.com').for(:email) }
    it { is_expected.not_to allow_value('userexample.com').for(:email) }

    # Distinct clauses of Devise.email_regexp (\A[^@\s]+@[^@\s]+\z): the missing-@
    # case is covered above; these pin the \s-exclusion and the single-@ shape so
    # that weakening the format regexp reddens at least one example. (An internal
    # space is NOT removed by strip_whitespace_keys, which only trims the ends.)
    it { is_expected.not_to allow_value('a b@example.com').for(:email) }
    it { is_expected.not_to allow_value('a@@example.com').for(:email) }
  end

  # Devise normalises the email before validation (config.case_insensitive_keys
  # and config.strip_whitespace_keys, both [:email]). This is what makes the
  # case-insensitive uniqueness above actually hold at the data layer, so it is
  # pinned explicitly: drop either key from devise.rb and one of these reddens.
  describe 'email normalisation on save' do
    it 'down-cases the email (case_insensitive_keys)' do
      user = create(:user, email: 'MixedCase@Example.COM')
      expect(user.reload.email).to eq('mixedcase@example.com')
    end

    it 'strips surrounding whitespace from the email (strip_whitespace_keys)' do
      user = create(:user, email: '  spaced@example.com  ')
      expect(user.reload.email).to eq('spaced@example.com')
    end
  end

  # The custom soft-delete-aware uniqueness validation
  # (unique_email_among_active_users) characterised through its OBSERVABLE
  # behaviour. NOTE: SoftDeletable adds `default_scope { where(deleted_at: nil) }`,
  # so the `User.where(...)` inside the method already excludes soft-deleted rows;
  # the method's own `.where(deleted_at: nil)` is redundant belt-and-suspenders
  # (kept verbatim by the pure-move rule — removing it is an equivalent mutation,
  # see the mutation table in the PR). The cases below therefore pin behaviour,
  # not that single clause:
  #   - an anonymised soft-delete frees the email because anonymisation scrambles
  #     it away (the production GDPR path: schedule_deletion! -> anonymize!);
  #   - a soft-deleted-but-not-anonymised row likewise does not block reuse (the
  #     default scope hides the dead row);
  #   - two LIVE rows with the same email (case-insensitively) must collide —
  #     dropping the validation entirely reddens these.
  describe 'email uniqueness with soft delete' do
    let!(:original_user) { create(:user, email: 'test@example.com') }

    context 'when user is soft deleted and anonymised' do
      before { original_user.soft_delete_and_anonymize! }

      it 'allows creating new user with same original email' do
        new_user = build(:user, email: 'test@example.com')
        expect(new_user).to be_valid
      end

      it 'creates new user successfully' do
        expect { create(:user, email: 'test@example.com') }.not_to raise_error
      end
    end

    context 'when a soft-deleted row still carries the email (not yet anonymised)' do
      before { original_user.soft_delete! }

      it 'does not block a new active user from reusing that email' do
        new_user = build(:user, email: 'test@example.com')
        expect(new_user).to be_valid
      end
    end

    context 'when user is active' do
      it 'prevents duplicate emails' do
        duplicate_user = build(:user, email: 'test@example.com')
        expect(duplicate_user).not_to be_valid
        expect(duplicate_user.errors[:email]).to be_present
      end

      it 'is case-insensitive' do
        duplicate_user = build(:user, email: 'TEST@EXAMPLE.COM')
        expect(duplicate_user).not_to be_valid
        expect(duplicate_user.errors[:email]).to be_present
      end
    end
  end

  # Defense in depth: email uniqueness is enforced at TWO layers — the model
  # validations above AND the partial unique index `index_users_on_email_active`
  # (UNIQUE WHERE deleted_at IS NULL). These examples bypass the model layer with
  # save!(validate: false) to prove the DB layer stands on its own. If someone
  # ever drops the model validations as "redundant", the first example stays
  # green; if they drop the partiality of the index, the second reddens.
  describe 'email uniqueness at the DB layer (defense in depth)' do
    it 'raises RecordNotUnique for two active rows even with model validation bypassed' do
      create(:user, email: 'dup-db@example.com')
      racer = build(:user, email: 'dup-db@example.com')
      expect { racer.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'permits an active row to reuse a soft-deleted row email (index is partial)' do
      original = create(:user, email: 'reuse-db@example.com')
      original.soft_delete!
      fresh = build(:user, email: 'reuse-db@example.com')

      expect { fresh.save!(validate: false) }.not_to raise_error
      expect(fresh).to be_persisted
    end
  end

  describe 'password validation' do
    it { is_expected.to validate_presence_of(:password) }

    it 'validates password confirmation' do
      user = build(:user, password: 'password123', password_confirmation: 'password123')
      expect(user).to be_valid

      user = build(:user, password: 'password123', password_confirmation: 'different')
      expect(user).not_to be_valid
      expect(user.errors[:password_confirmation]).to be_present
    end

    # Length boundary at the n-1/n edges. The app does NOT use Devise
    # :validatable (so config.password_length is inert) — the floor is the
    # custom `length: { minimum: 6 }`. 5 chars must fail, 6 chars must pass:
    # together they pin the minimum to exactly 6 (a `minimum: 1` mutant reddens
    # the reject; a `minimum: 7` mutant reddens the accept).
    it 'rejects a password shorter than the 6-character minimum' do
      user = build(:user, password: 'abc12', password_confirmation: 'abc12')
      expect(user).not_to be_valid
      expect(user.errors[:password]).to be_present
    end

    it 'accepts a password of exactly the 6-character minimum' do
      user = build(:user, password: 'abc123', password_confirmation: 'abc123')
      expect(user).to be_valid
    end
  end

  # password_required? is the gate that lets a profile update save without
  # re-supplying a password while still forcing password rules on creation and
  # on an explicit password change. All three branches are pinned behaviourally
  # (via validity), never by calling the private method directly.
  describe 'password requirement gating (custom, since we are not using :validatable)' do
    it 'requires a password on a brand-new record' do
      user = build(:user, password: nil, password_confirmation: nil)
      expect(user).not_to be_valid
      expect(user.errors[:password]).to be_present
    end

    it 'does not require a password when a persisted record is updated without changing it' do
      created = create(:user)
      # A freshly fetched instance carries no virtual password (reload would NOT
      # clear the in-memory @password, so it cannot stand in for this).
      user = User.find(created.id)
      expect(user.password).to be_nil

      # Drive the real persist path, not just #valid?: a profile-only update must
      # round-trip to the DB without re-supplying a password.
      expect { user.update!(first_name: 'Renamed') }.not_to raise_error
      expect(user.reload.first_name).to eq('Renamed')
    end

    it 'enforces password rules again the moment a persisted record sets a password' do
      created = create(:user)
      user = User.find(created.id)

      user.password = 'abc12' # 5 chars => below the minimum
      user.password_confirmation = 'abc12'
      expect(user).not_to be_valid
      expect(user.errors[:password]).to be_present
    end

    it 'still requires the password when ONLY the confirmation is set on a persisted record' do
      # Pins the third clause of password_required? (|| !password_confirmation.nil?):
      # the first two clauses (new record / password set) are false here, so only
      # that clause keeps the password rules switched on. Drop it and a persisted
      # record that supplies a stray confirmation but no password slips through as
      # valid — this example reddens in that case.
      created = create(:user)
      user = User.find(created.id)

      user.password_confirmation = 'orphan-confirmation'
      expect(user).not_to be_valid
      expect(user.errors[:password]).to be_present
    end
  end

  describe 'session timeout' do
    # Contract guard: the allow-list is referenced externally as
    # User::ALLOWED_SESSION_TIMEOUTS (app/views/user_preferences/session.html.erb
    # and below). It must resolve as a User constant and hold exactly these four
    # values; removing it from User raises NameError here.
    it 'pins User::ALLOWED_SESSION_TIMEOUTS to the exact allow-list' do
      expect(User::ALLOWED_SESSION_TIMEOUTS).to eq([30, 120, 480, 1440])
    end

    describe 'session_timeout_minutes validation' do
      # Iterating the allow-list proves the inclusion validation resolves the
      # bareword constant to User::ALLOWED_SESSION_TIMEOUTS; pairing it with the
      # rejected arbitrary value pins the validation to exactly that list.
      it 'accepts allowed values' do
        User::ALLOWED_SESSION_TIMEOUTS.each do |minutes|
          user = build(:user, session_timeout_minutes: minutes)
          expect(user).to be_valid, "expected #{minutes} to be allowed"
        end
      end

      it 'rejects arbitrary values' do
        user = build(:user, session_timeout_minutes: 5)
        expect(user).not_to be_valid
        expect(user.errors[:session_timeout_minutes]).to be_present
      end

      # Negative breadth over a HARDCODED list (not the constant): includes the
      # zero-bug (0 = degenerate "no timeout"), the values adjacent to the
      # allow-list entries (29/31, 1439/1441) and a negative. This hardens the
      # inclusion check against being loosened into a permissive range and against
      # the zero special-case slipping through.
      [0, -30, 29, 31, 119, 1439, 1441, 9999].each do |bad|
        it "rejects #{bad} (outside the allow-list)" do
          expect(build(:user, session_timeout_minutes: bad)).not_to be_valid
        end
      end

      it 'rejects nil' do
        user = build(:user, session_timeout_minutes: nil)
        expect(user).not_to be_valid
      end
    end

    describe '#timeout_in' do
      it 'overrides Devise timeout_in with the per-user value' do
        user = build(:user, session_timeout_minutes: 480)
        expect(user.timeout_in).to eq(480.minutes)
      end

      it 'defaults to 30 minutes for new users' do
        user = create(:user)
        expect(user.session_timeout_minutes).to eq(30)
        expect(user.timeout_in).to eq(30.minutes)
      end
    end
  end

  # Integration coverage for the Devise lifecycle, on real records and with no
  # doubles — the point is to exercise the very code the devise() macro wires in,
  # so a broken registration cannot pass silently.
  describe 'Devise lifecycle (integration, no stubs)' do
    describe 'database_authenticatable' do
      it 'accepts the correct password and rejects a wrong one' do
        user = create(:user, password: 'correct-horse', password_confirmation: 'correct-horse')
        expect(user.valid_password?('correct-horse')).to be(true)
        expect(user.valid_password?('wrong-password')).to be(false)
      end

      it 'stores only a bcrypt digest, never the plaintext password' do
        plaintext = 'PlAiNtExT-never-stored-8'
        user = create(:user, password: plaintext, password_confirmation: plaintext)

        raw = ActiveRecord::Base.connection.select_value(
          "SELECT encrypted_password FROM users WHERE id = #{ActiveRecord::Base.connection.quote(user.id)}"
        )
        expect(raw).to be_present
        expect(raw).not_to include(plaintext)
        expect(raw).to start_with('$2') # bcrypt marker ($2a$/$2b$)
      end

      it 'round-trips a password containing special characters' do
        pw = 'p@ss/w+rd_=with.$pecial 99'
        user = create(:user, password: pw, password_confirmation: pw)

        expect(user.reload.valid_password?(pw)).to be(true)
        expect(user.valid_password?('p@ss/w+rd_=with.$pecial 98')).to be(false)
      end
    end

    describe 'recoverable' do
      it 'issues a reset token, delivers instructions and resets via that token' do
        user = create(:user, password: 'original-pw-1', password_confirmation: 'original-pw-1')

        raw_token = nil
        expect do
          with_delivered_mails { raw_token = user.send_reset_password_instructions }
        end.to change { ActionMailer::Base.deliveries.size }.by(1)

        expect(raw_token).to be_present
        expect(user.reload.reset_password_token).to be_present
        expect(user.reset_password_sent_at).to be_present

        recovered = User.reset_password_by_token(
          reset_password_token: raw_token,
          password: 'brand-new-pw-2',
          password_confirmation: 'brand-new-pw-2'
        )
        expect(recovered.errors).to be_empty
        expect(user.reload.valid_password?('brand-new-pw-2')).to be(true)
      end

      it 'rejects a reset with an invalid token and leaves the password unchanged' do
        user = create(:user, password: 'keep-this-pw-4', password_confirmation: 'keep-this-pw-4')

        result = User.reset_password_by_token(
          reset_password_token: 'definitely-not-a-valid-token',
          password: 'hijacked-pw-9',
          password_confirmation: 'hijacked-pw-9'
        )
        expect(result.errors[:reset_password_token]).to be_present
        expect(user.reload.valid_password?('keep-this-pw-4')).to be(true)
      end

      it 'clears the token after a successful reset so it cannot be replayed' do
        user = create(:user, password: 'orig-pw-5', password_confirmation: 'orig-pw-5')
        raw_token = user.send_reset_password_instructions

        User.reset_password_by_token(
          reset_password_token: raw_token,
          password: 'new-pw-55', password_confirmation: 'new-pw-55'
        )
        expect(user.reload.reset_password_token).to be_nil

        replay = User.reset_password_by_token(
          reset_password_token: raw_token,
          password: 'replay-pw-66', password_confirmation: 'replay-pw-66'
        )
        expect(replay.errors[:reset_password_token]).to be_present
        expect(user.reload.valid_password?('new-pw-55')).to be(true)
      end

      it 'rejects a token older than reset_password_within (6h)' do
        user = create(:user, password: 'orig-pw-6', password_confirmation: 'orig-pw-6')

        raw_token = nil
        travel_to(Time.utc(2030, 1, 1, 12, 0, 0)) do
          raw_token = user.send_reset_password_instructions
        end

        travel_to(Time.utc(2030, 1, 1, 12, 0, 0) + Devise.reset_password_within + 1.minute) do
          result = User.reset_password_by_token(
            reset_password_token: raw_token,
            password: 'too-late-pw-7', password_confirmation: 'too-late-pw-7'
          )
          expect(result.errors).not_to be_empty
        end
        expect(user.reload.valid_password?('orig-pw-6')).to be(true)
      end
    end

    describe 'lockable' do
      it 'locks the account after the configured number of failed attempts and issues an unlock token' do
        user = create(:user, password: 'right-password-3', password_confirmation: 'right-password-3')

        expect(user.access_locked?).to be(false)
        # Drive the real failed-attempts flow: a block returning false marks the
        # authentication as failed. unlock_strategy is :both, so locking issues a token.
        # The loop re-runs the same per-attempt query by design (it simulates N
        # separate sign-in attempts), so Prosopite's N+1 scan is paused around it.
        Prosopite.pause
        Devise.maximum_attempts.times { user.valid_for_authentication? { false } }
        Prosopite.resume

        expect(user.access_locked?).to be(true)
        expect(user.failed_attempts).to be >= Devise.maximum_attempts
        expect(user.unlock_token).to be_present
      end

      it 'does NOT lock after one fewer than the maximum failed attempts (n-1 boundary)' do
        user = create(:user, password: 'right-password-3b', password_confirmation: 'right-password-3b')

        Prosopite.pause
        (Devise.maximum_attempts - 1).times { user.valid_for_authentication? { false } }
        Prosopite.resume

        expect(user.failed_attempts).to eq(Devise.maximum_attempts - 1)
        expect(user.access_locked?).to be(false)
      end

      it 'unlocks again via the unlock token, clearing lock and failed attempts' do
        user = create(:user, password: 'right-password-3c', password_confirmation: 'right-password-3c')

        Prosopite.pause
        Devise.maximum_attempts.times { user.valid_for_authentication? { false } }
        Prosopite.resume
        expect(user.access_locked?).to be(true)

        raw_token = user.send_unlock_instructions # issues a fresh raw unlock token
        unlocked = User.unlock_access_by_token(raw_token)

        expect(unlocked.errors).to be_empty
        expect(user.reload.access_locked?).to be(false)
        expect(user.failed_attempts).to eq(0)
        expect(user.locked_at).to be_nil
      end
    end

    describe 'rememberable' do
      it 'stamps remember_created_at when remember_me! is called' do
        user = create(:user)
        expect(user.remember_created_at).to be_nil

        user.remember_me!
        expect(user.reload.remember_created_at).to be_present
      end
    end

    describe 'timeoutable' do
      # Ties Devise's timedout? to OUR per-user timeout_in override. The window is
      # deliberately 120 minutes — a NON-default value (the global Devise default
      # is 30). Besides the strict just-over / just-under boundary, the 60-minute
      # probe is the discriminator: it is INSIDE the per-user 120-min window (not
      # timed out) but WOULD be timed out under the 30-min global default. So this
      # example fails if timeout_in ever falls back to the global value instead of
      # the per-user one (e.g. the Devise::Models::Timeoutable shadowing). Time is
      # frozen at a sub-second-zero instant so the boundary is unambiguous.
      it 'times a session out past the per-user window, consulting the per-user value' do
        travel_to(Time.utc(2030, 1, 1, 12, 0, 0)) do
          user = build(:user, session_timeout_minutes: 120)
          expect(user.timedout?(121.minutes.ago)).to be(true)
          expect(user.timedout?(119.minutes.ago)).to be(false)
          expect(user.timedout?(60.minutes.ago)).to be(false) # would be true under the 30-min global
        end
      end
    end

    describe 'reconfirmable email change' do
      # CVE-2026-32700 (GHSA-57hq-95w6-v4fc). Two concurrent email changes could leave
      # unconfirmed_email pointing at one address while the confirmation token went to
      # another: a repeated change to the SAME address did not write unconfirmed_email at
      # all, because the value had not changed and the partial UPDATE skipped the column.
      # devise 5.0.3 forces the column into every postponed change. The pin: the second
      # change to the same address still writes it (saved_changes lists forced columns
      # even when old and new value are equal).
      it 'writes unconfirmed_email again when the same new address is submitted twice' do
        user = create(:user, email: 'old@example.com')

        user.update!(email: 'new@example.com')
        expect(user.reload.unconfirmed_email).to eq('new@example.com')

        user.update!(email: 'new@example.com')
        expect(user.saved_changes).to include('unconfirmed_email')
      end
    end

    describe 'confirmable grace period' do
      # The countdown the banner prints and the lockout Devise enforces must
      # read the SAME clock, or a user is told "1 day left" on an account that
      # is already refused. Both anchor on created_at — NOT on
      # confirmation_sent_at, which every resend rewrites.
      describe '#confirmation_grace_days_left' do
        it 'counts whole days down from account creation and clamps at zero' do
          user = create(:user, :unconfirmed)

          user.update_columns(created_at: Time.current)
          expect(user.confirmation_grace_days_left).to eq(3)

          user.update_columns(created_at: 2.days.ago)
          expect(user.confirmation_grace_days_left).to eq(1)

          # Elapsed — clamped, or the banner would print "-4 days left".
          user.update_columns(created_at: 7.days.ago)
          expect(user.confirmation_grace_days_left).to eq(0)
        end

        it 'is nil for a confirmed account — there is no deadline to show' do
          expect(create(:user).confirmation_grace_days_left).to be_nil
        end
      end

      describe '#awaiting_confirmation?' do
        it 'is true only while the address is unproven' do
          expect(create(:user, :unconfirmed).awaiting_confirmation?).to be(true)
          expect(create(:user).awaiting_confirmation?).to be(false)
        end
      end

      # The override lives on the User class (ancestor reason documented there).
      # Resending rewrites confirmation_sent_at; created_at cannot move, so no
      # amount of resending extends the window.
      describe '#confirmation_period_valid?' do
        it 'measures from created_at, not from the last confirmation mail' do
          user = create(:user, :unconfirmed)

          user.update_columns(created_at: 1.day.ago, confirmation_sent_at: 1.day.ago)
          expect(user.confirmation_period_valid?).to be(true)

          # A fresh mail on an old account: Devise's own implementation would
          # answer true here. Ours must not.
          user.update_columns(created_at: 10.days.ago, confirmation_sent_at: Time.current)
          expect(user.confirmation_period_valid?).to be(false)
        end
      end
    end
  end
end
