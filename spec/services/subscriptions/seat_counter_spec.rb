# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Subscriptions::SeatCounter, type: :service do
  let(:account) { create(:account) }

  def billable_membership_in(org, user: create(:user))
    ActsAsTenant.with_tenant(org) do
      role = create(:role, organisation: org, billable: true)
      create(:membership, user: user, organisation: org, role: role, active: true)
    end
  end

  def guest_membership_in(org, user: create(:user))
    ActsAsTenant.with_tenant(org) do
      role = create(:role, organisation: org, billable: false)
      create(:membership, user: user, organisation: org, role: role, active: true)
    end
  end

  describe '#call' do
    it 'counts one seat for one billable membership' do
      org = create(:organisation, account: account)
      billable_membership_in(org)

      expect(described_class.new(account).call).to eq(1)
    end

    it 'excludes non-billable (guest) role memberships' do
      org = create(:organisation, account: account)
      guest_membership_in(org)

      expect(described_class.new(account).call).to eq(0)
    end

    it 'excludes deactivated memberships' do
      org = create(:organisation, account: account)
      ActsAsTenant.with_tenant(org) do
        role = create(:role, organisation: org, billable: true)
        create(:membership, user: create(:user), organisation: org, role: role, active: false)
      end

      expect(described_class.new(account).call).to eq(0)
    end

    it 'dedups the same billable user across 2+ organisations of the same account' do
      org_a = create(:organisation, account: account)
      org_b = create(:organisation, account: account)
      shared_user = create(:user)

      billable_membership_in(org_a, user: shared_user)
      billable_membership_in(org_b, user: shared_user)

      expect(described_class.new(account).call).to eq(1)
    end

    it 'counts distinct billable users across organisations separately' do
      org_a = create(:organisation, account: account)
      org_b = create(:organisation, account: account)

      billable_membership_in(org_a)
      billable_membership_in(org_b)

      expect(described_class.new(account).call).to eq(2)
    end

    # [CRITICAL] D4.1: no cross-account dedup. UserA is a billable seat in this
    # account's org AND independently owns/uses an entirely separate account --
    # that must not reduce this account's seat count.
    it 'does not dedup across independent accounts (D4.1)' do
      org = create(:organisation, account: account)
      shared_user = create(:user)
      billable_membership_in(org, user: shared_user)

      other_account = create(:account)
      other_org = create(:organisation, account: other_account)
      billable_membership_in(other_org, user: shared_user)

      expect(described_class.new(account).call).to eq(1)
      expect(described_class.new(other_account).call).to eq(1)
    end

    it 'returns 0 for an account with no organisations' do
      expect(described_class.new(account).call).to eq(0)
    end

    # D7: the missing rescue is the property under test here, not an oversight.
    it 'propagates errors instead of silently skipping a broken organisation' do
      good_org = create(:organisation, account: account)
      billable_membership_in(good_org)
      broken_org = create(:organisation, account: account)
      allow(broken_org).to receive(:memberships).and_raise(StandardError, 'boom')
      allow(account).to receive(:organisations).and_return([good_org, broken_org])

      expect do
        described_class.new(account).call
      end.to raise_error(StandardError, 'boom')
    end
  end
end
