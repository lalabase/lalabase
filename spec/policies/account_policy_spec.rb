# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccountPolicy, :ci_guard, type: :policy do
  let(:owner) { create(:user) }
  let(:other_user) { create(:user) }
  let(:account) { create(:account, owner: owner) }

  describe '#manage_billing?' do
    it 'allows the account owner' do
      expect(described_class.new(owner, account)).to be_manage_billing
    end

    # [CRITICAL] D4: being the account owner is the only requirement -- any
    # other user (e.g. an org admin of a bundled org) must NOT be able to
    # manage billing just because they have admin rights in one of the
    # account's orgs.
    it 'denies any other user' do
      expect(described_class.new(other_user, account)).not_to be_manage_billing
    end

    it 'denies everyone for an orphan account (owner: nil, D11)' do
      orphan_account = create(:account, owner: nil)

      expect(described_class.new(other_user, orphan_account)).not_to be_manage_billing
    end

    # [CRITICAL] D9 on the OWNER branch, missing until 2026-08-06. #eligible_owner? has
    # always applied "globally active and not soft-deleted" to the account_admin branch;
    # the owner branch was a bare id comparison, so deactivating the owner left them full
    # write access to the invoice master data and, through RolePolicy#update_billable?,
    # to the seat price of every bundled organisation.
    #
    # Reachable, not theoretical: active_for_authentication? is overridden only for system
    # accounts, so a user with active: false can still sign in.
    [
      ['a deactivated owner', ->(user) { user.update!(active: false) }],
      ['a soft-deleted owner', ->(user) { user.update!(deleted_at: Time.current) }]
    ].each do |label, deactivate|
      it "denies #{label}" do
        account
        deactivate.call(owner)

        expect(described_class.new(owner, account)).not_to be_manage_billing
        # The read side was built on #owner? too, so the same gap sat behind it.
        expect(described_class.new(owner, account)).not_to be_show_overview
      end
    end
  end

  # E6: seats and the bundled organisations are readable for every active
  # account_admin of a bundled org, while the invoice master data stays with the
  # owner. That split is the whole point of having two predicates, so the last
  # case below pins the split itself rather than either side of it.
  describe '#show_overview? (E6)' do
    it 'allows the account owner' do
      expect(described_class.new(owner, account)).to be_show_overview
    end

    it 'denies a user with no relationship to the account' do
      create(:organisation, account: account)

      expect(described_class.new(other_user, account)).not_to be_show_overview
    end

    it 'allows an active account_admin of a bundled organisation' do
      org = create(:organisation, account: account)
      admin = create(:user)
      ActsAsTenant.with_tenant(org) do
        create(:membership, user: admin, organisation: org,
                            role: create(:admin_role, organisation: org))
      end

      expect(described_class.new(admin, account)).to be_show_overview
    end

    it 'denies a regular member of a bundled organisation' do
      org = create(:organisation, account: account)
      member = create(:user)
      ActsAsTenant.with_tenant(org) do
        create(:membership, user: member, organisation: org,
                            role: create(:role, organisation: org))
      end

      expect(described_class.new(member, account)).not_to be_show_overview
    end

    # [CRITICAL] The with_tenant trap (§11 "Multi-Tenancy"): Role is
    # acts_as_tenant(:organisation), so an account_admin role only resolves under
    # ITS OWN organisation's tenant -- not under whatever tenant happens to be
    # active during the request. With a foreign tenant set, an implementation
    # that forgot the per-org with_tenant reads no role at all and silently
    # denies a legitimate reader. Invisible in production today, because every
    # account there bundles exactly one organisation; this is the only thing that
    # catches it before the first real agency account.
    it 'recognises the admin role in an organisation that is NOT the current tenant' do
      admin_org = create(:organisation, account: account)
      other_org = create(:organisation, account: account)
      admin = create(:user)
      ActsAsTenant.with_tenant(admin_org) do
        create(:membership, user: admin, organisation: admin_org,
                            role: create(:admin_role, organisation: admin_org))
      end

      result = ActsAsTenant.with_tenant(other_org) do
        described_class.new(admin, account).show_overview?
      end

      expect(result).to be(true)
    end

    it 'denies a deactivated account_admin of a bundled organisation' do
      org = create(:organisation, account: account)
      suspended = create(:user)
      ActsAsTenant.with_tenant(org) do
        create(:membership, user: suspended, organisation: org, active: false,
                            role: create(:admin_role, organisation: org))
      end

      expect(described_class.new(suspended, account)).not_to be_show_overview
    end

    # The split itself: reading the overview must NOT drag the invoice master
    # data along. Without this case, collapsing the two predicates into one would
    # still pass every other test in this file.
    it 'does not imply manage_billing? for the account_admin' do
      org = create(:organisation, account: account)
      admin = create(:user)
      ActsAsTenant.with_tenant(org) do
        create(:membership, user: admin, organisation: org,
                            role: create(:admin_role, organisation: org))
      end
      policy = described_class.new(admin, account)

      expect(policy).to be_show_overview
      expect(policy).not_to be_manage_billing
    end
  end

  describe '#manage_orgs?' do
    it 'allows the account owner' do
      expect(described_class.new(owner, account)).to be_manage_orgs
    end

    it 'denies any other user' do
      expect(described_class.new(other_user, account)).not_to be_manage_orgs
    end
  end

  describe '#claim? (D11)' do
    let(:orphan_account) { create(:account, owner: nil) }

    it 'allows the account_admin of one of the account\'s organisations' do
      org = create(:organisation, account: orphan_account)
      admin = create(:user)
      ActsAsTenant.with_tenant(org) do
        admin_role = create(:admin_role, organisation: org)
        create(:membership, user: admin, organisation: org, role: admin_role)
      end

      expect(described_class.new(admin, orphan_account)).to be_claim
    end

    # [CRITICAL] role_in_organisation finds a Membership by organisation_id
    # alone, with no active filter -- normally masked by
    # set_current_membership gating every real controller path on active
    # membership first. claim? has no controller yet, so that gate cannot be
    # assumed: a suspended account_admin must not be able to seize billing
    # ownership of an orphan Account.
    it 'denies a DEACTIVATED account_admin of one of the account\'s organisations' do
      org = create(:organisation, account: orphan_account)
      suspended_admin = create(:user)
      ActsAsTenant.with_tenant(org) do
        admin_role = create(:admin_role, organisation: org)
        create(:membership, user: suspended_admin, organisation: org, role: admin_role, active: false)
      end

      expect(described_class.new(suspended_admin, orphan_account)).not_to be_claim
    end

    it 'denies a regular (non-admin) member of one of the account\'s organisations' do
      org = create(:organisation, account: orphan_account)
      member = create(:user)
      ActsAsTenant.with_tenant(org) do
        regular_role = create(:role, organisation: org)
        create(:membership, user: member, organisation: org, role: regular_role)
      end

      expect(described_class.new(member, orphan_account)).not_to be_claim
    end

    it 'denies an account_admin of an unrelated organisation' do
      create(:organisation, account: orphan_account)
      other_org = create(:organisation)
      unrelated_admin = create(:user)
      ActsAsTenant.with_tenant(other_org) do
        admin_role = create(:admin_role, organisation: other_org)
        create(:membership, user: unrelated_admin, organisation: other_org, role: admin_role)
      end

      expect(described_class.new(unrelated_admin, orphan_account)).not_to be_claim
    end

    it 'denies claiming an account that already has an owner' do
      org = create(:organisation, account: account)
      admin = create(:user)
      ActsAsTenant.with_tenant(org) do
        admin_role = create(:admin_role, organisation: org)
        create(:membership, user: admin, organisation: org, role: admin_role)
      end

      expect(described_class.new(admin, account)).not_to be_claim
    end

    # Mutation guard: with only one organisation attached (every other case
    # above), `.any?` and `.all?` are indistinguishable. An orphan account
    # with TWO organisations, where the user is account_admin in only ONE of
    # them, tells them apart -- `.any?` (correct) still allows the claim,
    # `.all?` (a plausible-looking but wrong mutation) would wrongly deny it.
    it 'allows claiming when the user is account_admin in only ONE of several attached organisations' do
      admin_org = create(:organisation, account: orphan_account)
      other_org = create(:organisation, account: orphan_account)
      admin = create(:user)
      ActsAsTenant.with_tenant(admin_org) do
        admin_role = create(:admin_role, organisation: admin_org)
        create(:membership, user: admin, organisation: admin_org, role: admin_role)
      end
      ActsAsTenant.with_tenant(other_org) do
        regular_role = create(:role, organisation: other_org)
        create(:membership, user: admin, organisation: other_org, role: regular_role)
      end

      expect(described_class.new(admin, orphan_account)).to be_claim
    end

    # D9: eligibility now also requires the candidate to be globally active and
    # not soft-deleted -- otherwise staff could hand billing ownership to a user
    # who can never sign in, leaving an unmanageable Account with no orphan badge.
    it 'denies a globally deactivated account_admin (D9)' do
      org = create(:organisation, account: orphan_account)
      inactive_admin = create(:user, :inactive)
      ActsAsTenant.with_tenant(org) do
        admin_role = create(:admin_role, organisation: org)
        create(:membership, user: inactive_admin, organisation: org, role: admin_role)
      end

      expect(described_class.new(inactive_admin, orphan_account)).not_to be_claim
    end

    it 'denies a soft-deleted account_admin (D9)' do
      org = create(:organisation, account: orphan_account)
      deleted_admin = create(:user, :soft_deleted)
      ActsAsTenant.with_tenant(org) do
        admin_role = create(:admin_role, organisation: org)
        create(:membership, user: deleted_admin, organisation: org, role: admin_role)
      end

      expect(described_class.new(deleted_admin, orphan_account)).not_to be_claim
    end
  end
end
