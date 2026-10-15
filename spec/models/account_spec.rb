# frozen_string_literal: true

# == Schema Information
#
# Table name: accounts
#
#  id                                  :uuid             not null, primary key
#  acquisition                         :jsonb
#  billing_addressee                   :string
#  billing_city                        :string
#  billing_country                     :string(2)
#  billing_email                       :string
#  billing_email_cc                    :string
#  billing_interval                    :string           default("monthly"), not null
#  billing_name                        :string
#  billing_postal_code                 :string
#  billing_reference                   :string
#  billing_region                      :string
#  billing_starts_on                   :date
#  billing_street                      :string
#  billing_street_2                    :string
#  business_confirmation_version       :string
#  business_confirmed_at               :datetime
#  guest_max_organisations             :integer          default(1), not null
#  guest_max_projects_per_organisation :integer          default(1), not null
#  name                                :string           not null
#  payment_terms_days                  :integer          default(14), not null
#  plan_key                            :string           default("cloud"), not null
#  vat_id_checked_at                   :datetime
#  vat_id_checked_name                 :string
#  vat_id_status                       :string           default("unchecked"), not null
#  created_at                          :datetime         not null
#  updated_at                          :datetime         not null
#  business_confirmed_by_id            :uuid
#  owner_id                            :uuid
#  vat_id                              :string
#
# Indexes
#
#  index_accounts_on_billing_starts_on         (billing_starts_on)
#  index_accounts_on_business_confirmed_by_id  (business_confirmed_by_id)
#  index_accounts_on_owner_id                  (owner_id)
#
# Foreign Keys
#
#  fk_rails_...  (business_confirmed_by_id => users.id) ON DELETE => nullify
#  fk_rails_...  (owner_id => users.id) ON DELETE => nullify
#
require 'rails_helper'

RSpec.describe Account, type: :model do
  describe 'validations' do
    it { should validate_presence_of(:name) }

    it 'defaults guest ceilings to 1' do
      account = create(:account)

      expect(account.guest_max_organisations).to eq(1)
      expect(account.guest_max_projects_per_organisation).to eq(1)
    end

    it 'rejects a non-positive guest_max_organisations' do
      account = build(:account, guest_max_organisations: 0)

      expect(account).not_to be_valid
    end

    it 'rejects a non-positive guest_max_projects_per_organisation' do
      account = build(:account, guest_max_projects_per_organisation: 0)

      expect(account).not_to be_valid
    end

    it 'accepts a blank billing_email' do
      account = build(:account, billing_email: nil)

      expect(account).to be_valid
    end

    it 'rejects a malformed billing_email' do
      account = build(:account, billing_email: 'not-an-email')

      expect(account).not_to be_valid
    end
  end

  # W3 of doc/billing_rechnungsstellung_r1_plan.md (E2). Three plain columns
  # instead of a Subscription model -- under R1 the payment happens outside the
  # application, so an account has exactly one billing lifecycle state.
  describe 'billing state (W3)' do
    it 'starts unbilled with a monthly interval and a 14-day payment term' do
      account = create(:account)

      expect(account.billing_starts_on).to be_nil
      expect(account.billing_interval).to eq(Subscriptions::Constants::INTERVAL_MONTHLY)
      expect(account.payment_terms_days).to eq(14)
    end

    # Iterating the registry instead of naming 'monthly'/'yearly' by hand: a
    # third interval added to BILLING_INTERVALS must be accepted here without
    # anyone remembering to extend this spec.
    it 'accepts every interval the registry defines' do
      Subscriptions::Constants::BILLING_INTERVAL_KEYS.each do |key|
        expect(build(:account, billing_interval: key)).to be_valid
      end
    end

    it 'rejects an interval outside the registry' do
      account = build(:account, billing_interval: 'weekly')

      expect(account).not_to be_valid
    end

    # §13 of doc/billing_preisliste_rabatt_plan.md: new customers start without
    # the AI surcharge, and every existing account stayed there by the default.
    # The DATABASE default, not the factory's: every account that existed before
    # the column, and every one the signup creates, lands here without anyone
    # setting it.
    it 'starts on the plan without AI by the column default' do
      account = described_class.create!(name: 'Konto ohne Angabe')

      expect(account.reload.plan_key).to eq(Subscriptions::Constants::PLAN_CLOUD)
    end

    Subscriptions::Constants::PLAN_KEYS.each do |key|
      it "accepts the plan #{key}" do
        expect(build(:account, plan_key: key)).to be_valid
      end
    end

    ['enterprise', 'Cloud', ' cloud', 'cloud_ai ', ''].each do |bad|
      it "rejects the plan #{bad.inspect}" do
        account = build(:account, plan_key: bad)

        expect(account).not_to be_valid
        expect(account.errors[:plan_key]).to be_present
      end
    end

    # Defense in depth: the validation can be skipped, the column cannot be emptied.
    it 'refuses NULL in the database when the validation is bypassed' do
      account = create(:account)

      expect { account.update_column(:plan_key, nil) }.to raise_error(ActiveRecord::NotNullViolation)
    end

    it 'rejects a non-positive payment_terms_days' do
      expect(build(:account, payment_terms_days: 0)).not_to be_valid
    end

    # § 7 makes fees due IN ADVANCE for the period. A term longer than the period
    # makes that structurally impossible, and the ceiling comes from the registry
    # rather than from a number someone picked.
    describe 'payment_terms_days against the billing period' do
      it 'accepts a term that fits inside every registry interval' do
        Subscriptions::Constants::BILLING_INTERVAL_KEYS.each do |key|
          ceiling = Subscriptions::Constants.months_for(key) *
                    Subscriptions::Constants::DAYS_PER_MONTH_APPROX

          expect(build(:account, billing_interval: key, payment_terms_days: ceiling)).to be_valid
        end
      end

      it 'rejects a term that outlives its own billing period' do
        Subscriptions::Constants::BILLING_INTERVAL_KEYS.each do |key|
          ceiling = Subscriptions::Constants.months_for(key) *
                    Subscriptions::Constants::DAYS_PER_MONTH_APPROX
          account = build(:account, billing_interval: key, payment_terms_days: ceiling + 1)

          expect(account).not_to be_valid
          expect(account.errors[:payment_terms_days]).to be_present
        end
      end

      it 'is the concrete typo case: 60 days on a monthly account' do
        account = build(:account, billing_interval: Subscriptions::Constants::INTERVAL_MONTHLY,
                                  payment_terms_days: 60)

        expect(account).not_to be_valid
      end

      it 'accepts the same 60 days on a yearly account' do
        account = build(:account, billing_interval: Subscriptions::Constants::INTERVAL_YEARLY,
                                  payment_terms_days: 60)

        expect(account).to be_valid
      end

      # One mistake, one message: months_for raises for an unknown interval, so
      # this validation stands down and lets the inclusion validation speak.
      it 'reports only the interval when the interval itself is unknown' do
        account = build(:account, billing_interval: 'weekly', payment_terms_days: 9_999)

        expect { account.valid? }.not_to raise_error
        expect(account.errors[:billing_interval]).to be_present
        expect(account.errors[:payment_terms_days]).to be_empty
      end

      # Same courtesy for an unusable number: numericality rejects "60abc"
      # first, and the ceiling must not add a second message about the 60 the
      # cast invented.
      it 'reports only "not a number" for a non-numeric term' do
        account = build(:account, payment_terms_days: '60abc')

        expect(account).not_to be_valid
        expect(account.errors[:payment_terms_days].size).to eq(1)
        expect(account.errors[:payment_terms_days].first).to eq(I18n.t('errors.messages.not_a_number'))
      end

      # [CRITICAL] The ceiling judges a WRITE, never a row at rest. The form
      # shipped without an upper bound, so rows above it can exist; if such a row
      # were permanently invalid, every unrelated write on it would fail too.
      context 'with a legacy row above the ceiling' do
        let(:legacy) do
          account = create(:account)
          account.update_column(:payment_terms_days, 60) # bypasses validation, as the old form did
          account.reload
        end

        it 'leaves the row itself valid' do
          expect(legacy).to be_valid
        end

        it 'does not block an unrelated write' do
          expect { legacy.update!(name: 'Neuer Name') }.not_to raise_error
        end

        it 'does not block claim!, which would otherwise raise instead of assigning an owner' do
          org = create(:organisation, account: legacy)
          user = create(:user)
          ActsAsTenant.with_tenant(org) do
            create(:membership, user: user, organisation: org,
                                role: create(:role, organisation: org, title: 'account_admin'), active: true)
          end

          expect { legacy.claim!(user) }.not_to raise_error
          expect(legacy.reload.owner).to eq(user)
        end

        it 'still refuses to WRITE a new over-long term' do
          legacy.payment_terms_days = 45

          expect(legacy).not_to be_valid
        end

        # The other direction into illegality: the term stays, the period shrinks.
        # Starts from a YEARLY row, where 60 days is perfectly legal, so the
        # switch itself is what makes the pair illegal -- on a row that was
        # already monthly the interval would not have changed at all and the
        # validation would rightly stay out of it.
        it 'catches a switch to a shorter interval that makes the existing term too long' do
          yearly = create(:account, billing_interval: Subscriptions::Constants::INTERVAL_YEARLY,
                                    payment_terms_days: 60)
          expect(yearly).to be_valid

          yearly.billing_interval = Subscriptions::Constants::INTERVAL_MONTHLY

          expect(yearly).not_to be_valid
        end
      end
    end

    # A date column casts an unparsable string to nil, and nil is not neutral
    # here: it is the E4 marker for "not clarified". Reachable through a direct
    # PATCH, not through the browser's date field.
    describe 'billing_starts_on against a silent cast to nil' do
      it 'rejects a non-blank string that is not a date' do
        account = build(:account, billing_starts_on: 'naechsten Monat')

        expect(account).not_to be_valid
        expect(account.errors[:billing_starts_on]).to be_present
      end

      it 'still allows clearing the field back to "not clarified"' do
        account = create(:account, billing_starts_on: Date.new(2026, 9, 1))
        account.billing_starts_on = ''

        expect(account).to be_valid
        expect(account.billing_starts_on).to be_nil
      end

      it 'leaves an account that never had a start date valid' do
        expect(build(:account)).to be_valid
      end

      it 'accepts a parsable date string' do
        account = build(:account, billing_starts_on: '2026-09-01')

        expect(account).to be_valid
        expect(account.billing_starts_on).to eq(Date.new(2026, 9, 1))
      end
    end
  end

  # E4: NULL means "not clarified", NOT "free" -- deliberately free is a 100 %
  # AccountDiscount. Without that distinction a forgotten account and a
  # decided-to-be-free one would look identical in the billing list.
  describe '#billing_start_decided?' do
    it 'is false while billing_starts_on is nil' do
      expect(create(:account).billing_start_decided?).to be false
    end

    it 'is true once a start date is set' do
      expect(create(:account, billing_starts_on: Date.new(2026, 9, 1)).billing_start_decided?).to be true
    end

    it 'is true for a start date in the future (the decision, not the clock, sets this)' do
      expect(create(:account, billing_starts_on: Date.current + 30).billing_start_decided?).to be true
    end
  end

  describe 'associations' do
    it { should belong_to(:owner).class_name('User').optional }
    it { should have_many(:organisations).dependent(:restrict_with_exception) }

    it 'allows owner to be nil (system/factory accounts, D8)' do
      account = create(:account, owner: nil)

      expect(account).to be_valid
    end

    # [CRITICAL] dependent: :restrict_with_exception is the ONLY thing standing
    # between an Account#destroy and a cascading delete of every organisation
    # (and, transitively, every project/ticket/document in them -- Organisation
    # itself uses dependent: :destroy almost everywhere). Guard against a
    # future "helpful" simplification to :destroy or :nullify.
    it 'refuses to destroy an account that still has an organisation attached' do
      account = create(:account)
      create(:organisation, account: account)

      expect { account.destroy }.to raise_error(ActiveRecord::DeleteRestrictionError)
      expect(Account.exists?(account.id)).to be true
    end

    it 'can be destroyed once its organisation is gone' do
      account = create(:account)
      org = create(:organisation, account: account)
      ActsAsTenant.with_tenant(org) { org.destroy! }

      expect { account.destroy! }.not_to raise_error
    end
  end

  describe '.backfill_all! (Plan doc/billing_agentur_konto_plan.md D3, T4)' do
    it 'creates a 1:1 Account for every organisation missing one' do
      org = create(:organisation)
      org.update_column(:account_id, nil) # simulate a pre-callback legacy row

      expect do
        Account.backfill_all!
      end.to change(Account, :count).by(1)

      expect(org.reload.account).to be_present
      expect(org.account.name).to eq(org.name)
      expect(org.account.owner).to be_nil
    end

    it 'returns the number of backfilled organisations' do
      org1 = create(:organisation)
      org1.update_column(:account_id, nil)
      org2 = create(:organisation)
      org2.update_column(:account_id, nil)

      expect(Account.backfill_all!).to eq(2)
    end

    it 'is idempotent -- a second run changes nothing' do
      org = create(:organisation)
      org.update_column(:account_id, nil)

      Account.backfill_all!

      expect do
        Account.backfill_all!
      end.not_to change(Account, :count)
    end

    it 'does not touch organisations that already have an account' do
      org = create(:organisation)
      existing_account = org.account

      Account.backfill_all!

      expect(org.reload.account).to eq(existing_account)
    end
  end

  describe '#claim! (Plan doc/billing_agentur_konto_plan.md D11)' do
    it 'sets the owner of an orphan account' do
      account = create(:account, owner: nil)
      user = create(:user)

      account.claim!(user)

      expect(account.reload.owner).to eq(user)
    end

    it 'raises when the account already has an owner' do
      owner = create(:user)
      account = create(:account, owner: owner)
      other_user = create(:user)

      expect do
        account.claim!(other_user)
      end.to raise_error(Account::AlreadyClaimedError)

      expect(account.reload.owner).to eq(owner)
    end

    it 'raises ArgumentError for a nil user instead of silently claiming nothing' do
      account = create(:account, owner: nil)

      expect { account.claim!(nil) }.to raise_error(ArgumentError)
      expect(account.reload.owner).to be_nil
    end
  end

  # N4 (doc/billing_stammdaten_plan.md § 18): the operator counterpart to #claim!.
  describe '#reassign_owner! (N4)' do
    let(:account) { create(:account, owner: create(:user)) }
    let(:successor) { create(:user) }

    it 'replaces an existing owner' do
      account.reassign_owner!(successor)

      expect(account.reload.owner).to eq(successor)
    end

    # The difference to claim!, and the whole purpose of this method: there an
    # existing owner is an error, here it is the precondition.
    it 'does NOT raise on an account that already has an owner' do
      expect { account.reassign_owner!(successor) }.not_to raise_error
    end

    it 'returns the previous owner, so the message can say what was swapped' do
      previous = account.owner

      expect(account.reassign_owner!(successor)).to eq(previous)
    end

    # The method itself stays free of preconditions -- that is right for the console
    # and rake. The rule "an ownerless account belongs on assign_owner" belongs
    # in the operator path and is enforced in Admin::AccountsController#reassign_owner,
    # with its own spec.
    it 'returns nil when there was no previous owner' do
      ownerless = create(:account, owner: nil)

      expect(ownerless.reassign_owner!(successor)).to be_nil
    end

    it 'refuses a nil user instead of silently clearing the owner' do
      expect { account.reassign_owner!(nil) }.to raise_error(ArgumentError)
      expect(account.reload.owner).to be_present
    end

    # [CRITICAL] claim! must NOT become softer through this method: its
    # error protects the customer claim path against the race in which two
    # account_admins read "no owner yet" at the same time.
    it 'leaves claim! strict' do
      expect { account.claim!(successor) }.to raise_error(Account::AlreadyClaimedError)
    end
  end

  describe '#orphan?' do
    it 'is true when owner is nil' do
      expect(create(:account, owner: nil)).to be_orphan
    end

    it 'is false when an owner is set' do
      expect(create(:account, owner: create(:user))).not_to be_orphan
    end
  end

  # Owner-eligibility (Plan doc/admin_account_owner_plan.md, Baustein A, D9/W1).
  # Both methods enforce the SAME rule (one is the grouped list, the other the
  # single-user predicate), so the cases below deliberately mirror each other --
  # anything that drops out of the grouped list must also fail the predicate.
  #
  # Shared builder: attaches `user` to `org` with a role and membership state.
  # Runs under with_tenant because Role is acts_as_tenant(:organisation).
  def attach_member(org, user, role: :admin_role, active: true)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org,
                          role: create(role, organisation: org), active: active)
    end
  end

  describe '#eligible_owners_by_organisation (D9/W1)' do
    let(:account) { create(:account, owner: nil) }

    it 'includes an active account_admin of an attached organisation' do
      org = create(:organisation, account: account)
      admin = create(:user)
      attach_member(org, admin)

      expect(account.eligible_owners_by_organisation[org]).to contain_exactly(admin)
    end

    it 'excludes a deactivated membership (W1)' do
      org = create(:organisation, account: account)
      attach_member(org, create(:user), active: false)

      expect(account.eligible_owners_by_organisation[org]).to be_empty
    end

    it 'excludes a non-admin member' do
      org = create(:organisation, account: account)
      attach_member(org, create(:user), role: :role)

      expect(account.eligible_owners_by_organisation[org]).to be_empty
    end

    it 'excludes a globally deactivated user (D9)' do
      org = create(:organisation, account: account)
      attach_member(org, create(:user, :inactive))

      expect(account.eligible_owners_by_organisation[org]).to be_empty
    end

    it 'excludes a soft-deleted user (D9)' do
      org = create(:organisation, account: account)
      attach_member(org, create(:user, :soft_deleted))

      expect(account.eligible_owners_by_organisation[org]).to be_empty
    end

    it 'returns an empty hash for an account with no organisations' do
      expect(account.eligible_owners_by_organisation).to eq({})
    end

    it 'maps an organisation with no eligible admin to an empty group' do
      org = create(:organisation, account: account)

      expect(account.eligible_owners_by_organisation).to eq(org => [])
    end

    it 'lists a user who is account_admin in several attached organisations under each one' do
      org1 = create(:organisation, account: account)
      org2 = create(:organisation, account: account)
      admin = create(:user)
      attach_member(org1, admin)
      attach_member(org2, admin)

      result = account.eligible_owners_by_organisation

      expect(result[org1]).to contain_exactly(admin)
      expect(result[org2]).to contain_exactly(admin)
    end

    # Cross-scope-within-account: the SAME person is account_admin in one
    # attached org but only a plain member in another attached org. Eligibility
    # is per-org -- they must appear under the admin org and be ABSENT from the
    # member org's group, never leaked account-wide. A mutation that evaluated
    # the role against the wrong org (or dropped the per-org scoping) would leak
    # them into the member org and this fails.
    it 'lists the user only under the org where they are admin, not the org where they are a plain member' do
      admin_org = create(:organisation, account: account)
      member_org = create(:organisation, account: account)
      person = create(:user)
      attach_member(admin_org, person)
      attach_member(member_org, person, role: :role)

      result = account.eligible_owners_by_organisation

      expect(result[admin_org]).to contain_exactly(person)
      expect(result[member_org]).to be_empty
    end
  end

  describe '#eligible_owner? (D9/W1)' do
    let(:account) { create(:account, owner: nil) }

    it 'is true for an active account_admin of an attached organisation' do
      org = create(:organisation, account: account)
      admin = create(:user)
      attach_member(org, admin)

      expect(account.eligible_owner?(admin)).to be true
    end

    it 'is false for nil' do
      expect(account.eligible_owner?(nil)).to be false
    end

    it 'is false for a deactivated membership (W1)' do
      org = create(:organisation, account: account)
      admin = create(:user)
      attach_member(org, admin, active: false)

      expect(account.eligible_owner?(admin)).to be false
    end

    it 'is false for a non-admin member' do
      org = create(:organisation, account: account)
      member = create(:user)
      attach_member(org, member, role: :role)

      expect(account.eligible_owner?(member)).to be false
    end

    it 'is false for a globally deactivated user (D9)' do
      org = create(:organisation, account: account)
      inactive = create(:user, :inactive)
      attach_member(org, inactive)

      expect(account.eligible_owner?(inactive)).to be false
    end

    it 'is false for a soft-deleted user (D9)' do
      org = create(:organisation, account: account)
      deleted = create(:user, :soft_deleted)
      attach_member(org, deleted)

      expect(account.eligible_owner?(deleted)).to be false
    end

    it 'is false for an account_admin of an unrelated organisation' do
      create(:organisation, account: account)
      other_org = create(:organisation)
      unrelated = create(:user)
      attach_member(other_org, unrelated)

      expect(account.eligible_owner?(unrelated)).to be false
    end
  end
end
