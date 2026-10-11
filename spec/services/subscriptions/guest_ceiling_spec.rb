# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Subscriptions::GuestCeiling, type: :service do
  let(:account) { create(:account, guest_max_organisations: 1, guest_max_projects_per_organisation: 1) }

  def guest_membership_in(org, user:)
    ActsAsTenant.with_tenant(org) do
      role = create(:role, organisation: org, billable: false)
      create(:membership, user: user, organisation: org, role: role, active: true)
    end
  end

  def billable_membership_in(org, user:)
    ActsAsTenant.with_tenant(org) do
      role = create(:role, organisation: org, billable: true)
      create(:membership, user: user, organisation: org, role: role, active: true)
    end
  end

  def grant_project(org, user:)
    ActsAsTenant.with_tenant(org) do
      project = create(:project, organisation: org)
      create(:project_permission, user: user, project: project)
    end
  end

  describe '#violations' do
    it 'is empty when a guest stays within both limits' do
      org = create(:organisation, account: account)
      user = create(:user)
      guest_membership_in(org, user: user)
      grant_project(org, user: user)

      expect(described_class.new(account).violations).to be_empty
    end

    it 'flags a guest exceeding guest_max_organisations' do
      org_a = create(:organisation, account: account)
      org_b = create(:organisation, account: account)
      user = create(:user)
      guest_membership_in(org_a, user: user)
      guest_membership_in(org_b, user: user)

      violations = described_class.new(account).violations

      expect(violations.size).to eq(1)
      expect(violations.first.user).to eq(user)
      expect(violations.first).to be_over_organisation_limit
    end

    it 'flags a guest exceeding guest_max_projects_per_organisation in one organisation' do
      org = create(:organisation, account: account)
      user = create(:user)
      guest_membership_in(org, user: user)
      grant_project(org, user: user)
      grant_project(org, user: user)

      violations = described_class.new(account).violations

      expect(violations.size).to eq(1)
      expect(violations.first.organisations_over_project_limit.keys).to eq([org])
    end

    # [CRITICAL] Regel-Subjekt (Fund 1): a user billable ANYWHERE in the
    # account is already a paid seat -- their guest footprint elsewhere must
    # not be flagged as a violation.
    it 'does not flag a user who is billable in at least one organisation of the account' do
      org_a = create(:organisation, account: account)
      org_b = create(:organisation, account: account)
      user = create(:user)
      billable_membership_in(org_a, user: user)
      guest_membership_in(org_b, user: user)

      expect(described_class.new(account).violations).to be_empty
    end

    it 'does not flag a guest within an account with a higher configured ceiling' do
      generous_account = create(:account, guest_max_organisations: 3, guest_max_projects_per_organisation: 3)
      org_a = create(:organisation, account: generous_account)
      org_b = create(:organisation, account: generous_account)
      user = create(:user)
      guest_membership_in(org_a, user: user)
      guest_membership_in(org_b, user: user)

      expect(described_class.new(generous_account).violations).to be_empty
    end

    it 'does not aggregate an unrelated account\'s organisations into this account\'s check' do
      org = create(:organisation, account: account)
      other_account = create(:account, guest_max_organisations: 1)
      other_org_a = create(:organisation, account: other_account)
      other_org_b = create(:organisation, account: other_account)
      user = create(:user)
      guest_membership_in(org, user: user)
      guest_membership_in(other_org_a, user: user)
      guest_membership_in(other_org_b, user: user)

      expect(described_class.new(account).violations).to be_empty
    end

    it 'returns an empty array for an account with no organisations' do
      expect(described_class.new(account).violations).to eq([])
    end

    # A membership can reference a User row the default-scoped lookup cannot
    # see (soft-deleted user whose memberships were not yet destroyed, or an
    # orphaned row -- memberships has no FK on user_id). The sweep must skip
    # such users, not raise KeyError and take down the admin pages.
    it 'skips a violating membership whose user row is soft-deleted instead of raising' do
      org_a = create(:organisation, account: account)
      org_b = create(:organisation, account: account)
      user = create(:user)
      guest_membership_in(org_a, user: user)
      guest_membership_in(org_b, user: user)

      user.update_column(:deleted_at, Time.current) # memberships stay behind

      expect { described_class.new(account).violations }.not_to raise_error
      expect(described_class.new(account).violations).to be_empty
    end

    # D5-style active-membership filter (same correction as SeatCounter) --
    # a deactivated guest membership must not count towards the org limit.
    it 'ignores a deactivated guest membership when counting organisations' do
      org_a = create(:organisation, account: account)
      org_b = create(:organisation, account: account)
      user = create(:user)
      guest_membership_in(org_a, user: user)
      ActsAsTenant.with_tenant(org_b) do
        role = create(:role, organisation: org_b, billable: false)
        create(:membership, user: user, organisation: org_b, role: role, active: false)
      end

      expect(described_class.new(account).violations).to be_empty
    end

    # [CRITICAL] Plan-mandated regression case (§4.3 Fund 1): the reverse of
    # the test above. A DEACTIVATED billable membership must NOT count as
    # "billable anywhere" and must NOT protect the user from detection --
    # otherwise assigning a billable role and immediately deactivating it
    # would be an invisible free-seat cheat with no billing consequence.
    it 'does not let a deactivated billable membership shield a guest from detection' do
      org_a = create(:organisation, account: account)
      org_b = create(:organisation, account: account)
      org_c = create(:organisation, account: account)
      user = create(:user)
      ActsAsTenant.with_tenant(org_a) do
        billable_role = create(:role, organisation: org_a, billable: true)
        create(:membership, user: user, organisation: org_a, role: billable_role, active: false)
      end
      guest_membership_in(org_b, user: user)
      guest_membership_in(org_c, user: user)

      violations = described_class.new(account).violations

      expect(violations.map(&:user)).to contain_exactly(user)
    end

    # Mutation guard: a #filter_map -> #find/#first slip would only ever
    # surface the FIRST violating user and silently drop the rest -- exactly
    # what the Admin-Backend's violation count/list (§4.4) relies on being
    # complete.
    it 'returns violations for every independent user over the limit, not just the first' do
      org_a = create(:organisation, account: account)
      org_b = create(:organisation, account: account)
      user1 = create(:user)
      user2 = create(:user)
      guest_membership_in(org_a, user: user1)
      guest_membership_in(org_b, user: user1)
      guest_membership_in(org_a, user: user2)
      guest_membership_in(org_b, user: user2)

      violations = described_class.new(account).violations

      expect(violations.map(&:user)).to contain_exactly(user1, user2)
    end
  end

  describe '#violation_for (single-user variant used by the non-blocking hint)' do
    it 'returns nil when the user stays within both limits' do
      org = create(:organisation, account: account)
      user = create(:user)
      guest_membership_in(org, user: user)
      grant_project(org, user: user)

      expect(described_class.new(account).violation_for(user)).to be_nil
    end

    it 'returns a Violation when the user exceeds guest_max_organisations' do
      org_a = create(:organisation, account: account)
      org_b = create(:organisation, account: account)
      user = create(:user)
      guest_membership_in(org_a, user: user)
      guest_membership_in(org_b, user: user)

      violation = described_class.new(account).violation_for(user)

      expect(violation).to be_over_organisation_limit
    end

    it 'returns nil for a user who is billable anywhere in the account (Fund 1)' do
      org_a = create(:organisation, account: account)
      org_b = create(:organisation, account: account)
      user = create(:user)
      billable_membership_in(org_a, user: user)
      guest_membership_in(org_b, user: user)

      expect(described_class.new(account).violation_for(user)).to be_nil
    end

    it 'returns nil for a user without any membership in the account' do
      create(:organisation, account: account)
      user = create(:user)

      expect(described_class.new(account).violation_for(user)).to be_nil
    end

    it 'returns a Violation when the user exceeds guest_max_projects_per_organisation (not just the org limit)' do
      org = create(:organisation, account: account)
      user = create(:user)
      guest_membership_in(org, user: user)
      grant_project(org, user: user)
      grant_project(org, user: user)

      violation = described_class.new(account).violation_for(user)

      expect(violation).not_to be_over_organisation_limit
      expect(violation.organisations_over_project_limit.keys).to eq([org])
    end

    it 'does not let a deactivated billable membership shield a guest from detection' do
      org_a = create(:organisation, account: account)
      org_b = create(:organisation, account: account)
      user = create(:user)
      ActsAsTenant.with_tenant(org_a) do
        billable_role = create(:role, organisation: org_a, billable: true)
        create(:membership, user: user, organisation: org_a, role: billable_role, active: false)
      end
      guest_membership_in(org_b, user: user)
      grant_project(org_b, user: user)
      grant_project(org_b, user: user)

      expect(described_class.new(account).violation_for(user)).to be_present
    end

    # #violations and #violation_for must agree -- otherwise the Admin-Backend
    # (bulk) and the controller hint (single-user) could show contradictory
    # results for the exact same account/user.
    it 'agrees with #violations for the same user' do
      org_a = create(:organisation, account: account)
      org_b = create(:organisation, account: account)
      user = create(:user)
      guest_membership_in(org_a, user: user)
      guest_membership_in(org_b, user: user)

      from_bulk = described_class.new(account).violations.find { |v| v.user == user }
      from_single = described_class.new(account).violation_for(user)

      expect(from_single.organisation_count).to eq(from_bulk.organisation_count)
      expect(from_single.any_limit_exceeded?).to eq(from_bulk.any_limit_exceeded?)
    end
  end
end
