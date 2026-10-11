# frozen_string_literal: true

require 'rails_helper'

# Spec for PersonalAccessTokenPolicy — this policy had NO spec at all, despite
# governing API credentials. It is a pure OWNERSHIP policy: a token may be
# read / updated / destroyed ONLY by the user it belongs to, and the policy
# scope must never leak another user's tokens.
#
# WHY THE EXAMPLES LOOK THE WAY THEY DO (mutation-resistance)
# The security core is the ownership check `record.user_id == user.id`
# (owns_record?) and the scope `scope.where(user_id: user.id)`. Every member
# action is therefore tested from BOTH sides — the owner (permitted) AND a
# different user (forbidden) — so that flipping `==` to `!=`, dropping the guard,
# or widening the scope reddens at least one example. Collection actions
# (index/create/new) carry no ownership and are pinned positively.
#
# EQUIVALENT MUTANT (documented, not chased): create? is `user.present?`, but
# ApplicationPolicy#initialize already raises on a nil user, so the present?
# check can never observe nil inside the policy — `user.present? -> true` is
# behaviourally identical and cannot be killed by a constructable policy.
RSpec.describe PersonalAccessTokenPolicy, :ci_guard, type: :policy do
  let(:owner) { create(:user) }
  let(:other) { create(:user) }
  let(:organisation) { create(:organisation) }
  let(:own_token) { create(:personal_access_token, user: owner, organisations: [organisation]) }
  let(:foreign_token) { create(:personal_access_token, user: other, organisations: [organisation]) }

  describe 'collection actions (no record ownership involved)' do
    subject(:policy) { described_class.new(owner, PersonalAccessToken) }

    it 'permits index for any logged-in user' do
      expect(policy.index?).to be true
    end

    it 'permits create for a logged-in user' do
      expect(policy.create?).to be true
    end

    it 'aliases new? to create? (also permitted)' do
      expect(policy.new?).to be true
    end
  end

  describe 'member actions for the OWNER' do
    subject(:policy) { described_class.new(owner, own_token) }

    it 'permits show' do
      expect(policy.show?).to be true
    end

    it 'permits update and its edit? alias' do
      expect(policy.update?).to be true
      expect(policy.edit?).to be true
    end

    it 'permits destroy' do
      expect(policy.destroy?).to be true
    end
  end

  # SECURITY CORE: a token belonging to a DIFFERENT user. owns_record? is
  # `record.user_id == user.id`; each forbidden expectation here dies if `==`
  # becomes `!=`, if owns_record? is hard-wired true, or if any member action
  # stops delegating to it.
  describe 'member actions on ANOTHER user\'s token' do
    subject(:policy) { described_class.new(owner, foreign_token) }

    it 'forbids show' do
      expect(policy.show?).to be false
    end

    it 'forbids update and its edit? alias' do
      expect(policy.update?).to be false
      expect(policy.edit?).to be false
    end

    it 'forbids destroy' do
      expect(policy.destroy?).to be false
    end
  end

  describe 'without a user' do
    # ApplicationPolicy#initialize refuses a nil user outright (shared contract).
    it 'cannot even be constructed' do
      expect { described_class.new(nil, PersonalAccessToken) }
        .to raise_error(Pundit::NotAuthorizedError)
    end
  end

  describe PersonalAccessTokenPolicy::Scope do
    # The scope is the bulk-read guard (policy_scope in the index action). It
    # must return exactly the caller's own tokens. The foreign token is the kill
    # case for `scope.where(user_id: user.id)` -> `scope` (leak all) and for a
    # wrong user_id.
    it "returns only the caller's own tokens" do
      mine_a = create(:personal_access_token, user: owner, organisations: [organisation])
      mine_b = create(:personal_access_token, user: owner, organisations: [organisation])
      theirs = create(:personal_access_token, user: other, organisations: [organisation])

      resolved = described_class.new(owner, PersonalAccessToken.all).resolve

      expect(resolved).to contain_exactly(mine_a, mine_b)
      expect(resolved).not_to include(theirs)
    end

    it 'returns nothing for a user who owns no tokens (foreign tokens exist)' do
      create(:personal_access_token, user: other, organisations: [organisation])

      resolved = described_class.new(owner, PersonalAccessToken.all).resolve

      expect(resolved).to be_empty
    end
  end
end
