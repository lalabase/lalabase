# frozen_string_literal: true

require 'rails_helper'

# What: Subscriptions::VisibleAccounts, the precomputed form of
#       AccountPolicy#show_overview? (K4 of doc/konto_ebene_plan.md).
# Type: service spec.
# Why:  It is a SECOND expression of an authorisation rule that already exists in the
#       policy, chosen because the policy's own direction (walk the account's
#       organisations) fans out per row. Two expressions of one rule can drift, and the
#       direction they drift in is the dangerous one: this object decides what a page
#       LISTS, so a widening bug shows a stranger's account name and its organisations.
#
#       The examples below are therefore written against the policy's outcome, not
#       against this object's implementation -- each one names the user, and the last
#       group checks that both answers agree.
RSpec.describe Subscriptions::VisibleAccounts do
  def make_account_admin(user, org)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org, active: true,
                          role: create(:admin_role, organisation: org))
    end
  end

  def make_plain_member(user, org)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org, active: true,
                          role: create(:role, organisation: org))
    end
  end

  # [CRITICAL] N1 in its precomputed form. The owner is a member of nothing, which is the
  # agency case: somebody pays for a customer organisation they do not work in.
  it 'includes an account the user owns without any membership' do
    owner = create(:user)
    account = create(:account, owner: owner)
    create(:organisation, account: account)

    expect(described_class.call(user: owner)).to contain_exactly(account)
  end

  it 'includes an account the user is an active account_admin in' do
    admin = create(:user)
    account = create(:account, owner: create(:user))
    org = create(:organisation, account: account)
    make_account_admin(admin, org)

    expect(described_class.call(user: admin)).to contain_exactly(account)
  end

  it 'excludes an account where the user is only a plain member' do
    member = create(:user)
    account = create(:account, owner: create(:user))
    org = create(:organisation, account: account)
    make_plain_member(member, org)

    expect(described_class.call(user: member)).to be_empty
  end

  it 'excludes an account the user has nothing to do with' do
    outsider = create(:user)
    make_account_admin(outsider, create(:organisation, account: create(:account)))
    foreign = create(:account, owner: create(:user))
    create(:organisation, account: foreign)

    expect(described_class.call(user: outsider)).not_to include(foreign)
  end

  # An inactive membership is not a membership. Deactivating somebody has to take their
  # view of the money with it, otherwise a removed admin keeps reading the invoice data
  # of the organisation they were removed from.
  it 'excludes an account whose account_admin membership is inactive' do
    admin = create(:user)
    account = create(:account, owner: create(:user))
    org = create(:organisation, account: account)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: admin, organisation: org, active: false,
                          role: create(:admin_role, organisation: org))
    end

    expect(described_class.call(user: admin)).to be_empty
  end

  # D9, the invariant Account#eligible_owner? hoists for the same reason: a user who can
  # never sign in must not count as eligible anywhere.
  it 'returns nothing for a globally inactive user, even where they own the account' do
    owner = create(:user)
    account = create(:account, owner: owner)
    create(:organisation, account: account)
    owner.update!(active: false)

    expect(described_class.call(user: owner)).to be_empty
  end

  it 'returns nothing for a nil user' do
    expect(described_class.call(user: nil)).to be_empty
  end

  # Owner AND admin of the same account. Without the union this listed the account twice,
  # which the page would render as two identical rows.
  it 'lists an account once when the user is both its owner and an account_admin' do
    owner = create(:user)
    account = create(:account, owner: owner)
    org = create(:organisation, account: account)
    make_account_admin(owner, org)

    expect(described_class.call(user: owner)).to contain_exactly(account)
  end

  # An organisation without an account (account_id is still nullable, E9b) has nothing to
  # contribute, and a nil in the id list would match every account with a NULL id in some
  # database dialects rather than nothing.
  it 'ignores an organisation that has no account at all' do
    admin = create(:user)
    orphan_org = create(:organisation)
    orphan_org.update_columns(account_id: nil)
    make_account_admin(admin, orphan_org)

    expect(described_class.call(user: admin)).to be_empty
  end

  # The agreement check. This object exists only because the policy's direction is too
  # expensive per row; if the two ever disagree, the cheap one is wrong by definition.
  describe 'agreement with AccountPolicy#show_overview?' do
    it 'returns exactly the accounts the policy would admit' do
      owner = create(:user)
      owned = create(:account, owner: owner)
      create(:organisation, account: owned)

      administered = create(:account, owner: create(:user))
      make_account_admin(owner, create(:organisation, account: administered))

      member_only = create(:account, owner: create(:user))
      make_plain_member(owner, create(:organisation, account: member_only))

      unrelated = create(:account, owner: create(:user))
      create(:organisation, account: unrelated)

      all = [owned, administered, member_only, unrelated]
      by_policy = all.select { |account| AccountPolicy.new(owner, account).show_overview? }

      expect(described_class.call(user: owner)).to match_array(by_policy)
      # Pinned so the comparison cannot pass by both sides being empty or all-inclusive.
      expect(by_policy).to contain_exactly(owned, administered)
    end

    # The two cases the group above cannot reach, and the ones the answers actually
    # disagreed on until 2026-08-06: every user in that example is active and not
    # deleted, so it exercised only the branch where the D9 invariants never fire.
    #
    # The disagreement was visible to a real user: the account summary listed nothing
    # while the account page itself rendered in full. The defect was in the policy, whose
    # owner branch was a bare id comparison; it is fixed there, and this pins BOTH sides
    # so the next person cannot repair the symptom by loosening this object instead.
    [
      ['a deactivated owner', ->(user) { user.update!(active: false) }],
      ['a soft-deleted owner', ->(user) { user.update!(deleted_at: Time.current) }]
    ].each do |label, deactivate|
      it "agrees with the policy about #{label}" do
        owner = create(:user)
        account = create(:account, owner: owner)
        create(:organisation, account: account)
        deactivate.call(owner)

        expect(AccountPolicy.new(owner, account).show_overview?).to be(false)
        expect(described_class.call(user: owner)).to be_empty
      end
    end
  end
end
