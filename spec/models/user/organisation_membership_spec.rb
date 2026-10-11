# frozen_string_literal: true

require 'rails_helper'

# Specs for User::OrganisationMembership — the organisation-membership query
# helpers extracted from the User god-class (user.rb split, slice 7/7).
#
# WHAT THIS GUARDS
# This slice moves the membership lookup helpers (member_of_organisation?,
# active_member_of_organisation?, active_memberships, active_organisations,
# role_in_organisation) into a Concern that is mixed BACK INTO User. The methods
# stay instance methods on User, so every call site keeps working unchanged with
# zero migration. The slice is a pure refactoring: behaviour must stay
# bit-identical to the legacy User methods. Most examples here are
# CHARACTERIZATION tests — they pin what the app already does, not new
# requirements. Read them as "this is what the app already does and must keep
# doing".
#
# CROSS-TENANT BY DESIGN. User is deliberately NOT acts_as_tenant (a user can
# belong to many organisations), and Membership is deliberately NOT acts_as_tenant
# either. The membership queries here therefore run cross-tenant on purpose — the
# split must NOT "improve" them into tenant-scoped queries. The examples below
# call the methods without a current tenant precisely to pin that they work
# cross-tenant.
#
# NOTE ON SCOPE: Admin::User is a SEPARATE class (< ApplicationRecord, same
# users table, no acts_as_tenant) that keeps its OWN role_in_organisation with a
# different signature (it takes an organisation_id, not an object). That copy is
# deliberately NOT unified into this concern and is NOT covered here. This file
# only pins the User-side behaviour.
#
# WHY THE EXAMPLES LOOK THE WAY THEY DO (mutation-resistance)
# The two request-level caches (@role_cache, @active_member_cache) are the real
# risk of this move: both methods are called per-org / per-project in policies,
# the sidebar and navigation, so without the memo they would become a silent
# query N+1 (same trap as the org-count memo in slice 3). The query-count guards
# below assert exactly ONE membership query for two calls and reden if the memo
# is weakened (||= -> =, dropping the key? check, removing the memo). They are
# green against the pre-extraction code (proof: one query today) and the safety
# net after the extraction.
RSpec.describe User, type: :model do
  # Collect the SQL fired while running the block, dropping SCHEMA/TRANSACTION
  # noise (same idiom as spec/models/user/org_color_settings_spec.rb). Used by
  # the request-level-cache query-count guards below.
  def captured_sql(&block)
    sql = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    sql
  end

  describe '#member_of_organisation?' do
    let(:user) { create(:user) }
    let(:organisation) { create(:organisation) }

    context 'when user is a member of the organisation' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: user, organisation: organisation)
        end
      end

      it 'returns true' do
        expect(user.member_of_organisation?(organisation)).to be true
      end
    end

    context 'when user is not a member of the organisation' do
      it 'returns false' do
        expect(user.member_of_organisation?(organisation)).to be false
      end
    end

    # The cache key handles an id-or-object argument, and so does the query
    # (member_of_organisation? uses org_id in the WHERE, unlike
    # active_member_of_organisation?). Pin both so a refactor that drops the
    # is_a?(Organisation) coercion reddens here.
    it 'accepts the organisation id as well as the object' do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation)
      end
      expect(user.member_of_organisation?(organisation.id)).to be true
    end

    # Counts ANY membership, active or not. This is the distinguishing contract
    # vs active_member_of_organisation? below — an inactive membership still
    # makes you a "member". Inverting the active filter into this method reddens
    # the active_member spec, not this one; this pins the other direction.
    it 'returns true even for an inactive membership' do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, active: false)
      end
      expect(user.member_of_organisation?(organisation)).to be true
    end

    # CROSS-ORG ISOLATION. The "not a member" case above has NO membership at all,
    # so it cannot catch a mutant that drops the organisation_id filter (with zero
    # rows, every query is empty either way). Here the user IS a member of a
    # DIFFERENT org, so `memberships.where(organisation_id: org_id)` -> `memberships`
    # (filter dropped) would wrongly report membership and redden this.
    it 'returns false when the user only belongs to a different organisation' do
      other = create(:organisation)
      ActsAsTenant.with_tenant(other) do
        create(:membership, user: user, organisation: other)
      end
      expect(user.member_of_organisation?(organisation)).to be false
    end

    # The memberships.loaded? branch (in-memory `any?`) is otherwise never
    # exercised — a freshly created user goes through where.exists?. Preloading
    # forces the other branch; BOTH the positive and the cross-org negative must
    # hold there too, which kills `any?`->`none?` and `==`->`!=` mutants inside
    # the loaded branch. The query-count assertion additionally proves the branch
    # is actually TAKEN (zero membership queries) — without it a mutant that drops
    # the loaded? check entirely (always where.exists?) would still return the
    # right booleans and survive.
    it 'resolves from the in-memory association (no query) when memberships are loaded' do
      other = create(:organisation)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation)
      end
      fresh = User.find(user.id)
      fresh.memberships.load # memberships.loaded? => true (query is outside the measure)

      sql = captured_sql do
        expect(fresh.member_of_organisation?(organisation)).to be true
        expect(fresh.member_of_organisation?(other)).to be false
      end
      expect(sql.grep(/FROM "memberships"/i)).to be_empty
    end
  end

  describe '#active_member_of_organisation?' do
    let(:user) { create(:user) }
    let(:organisation) { create(:organisation) }

    it 'returns true for an active membership' do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, active: true)
      end
      expect(user.active_member_of_organisation?(organisation)).to be true
    end

    # The negative half of the contract that separates this method from
    # member_of_organisation?: an INACTIVE membership counts as a member but NOT
    # as an active member. Dropping the .active scope from the query reddens this.
    it 'returns false for an inactive membership' do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, active: false)
      end
      expect(user.active_member_of_organisation?(organisation)).to be false
      # Same row, the broader predicate still sees it — proves the two methods
      # genuinely diverge on the active filter, not on membership existence.
      expect(user.member_of_organisation?(organisation)).to be true
    end

    it 'returns false when there is no membership at all' do
      expect(user.active_member_of_organisation?(organisation)).to be false
    end

    # CROSS-ORG ISOLATION: an ACTIVE membership in a different org must not leak
    # in. The "no membership" case above cannot catch a dropped organisation_id
    # filter (zero rows); this can.
    it 'returns false for an active membership in a different organisation' do
      other = create(:organisation)
      ActsAsTenant.with_tenant(other) do
        create(:membership, user: user, organisation: other, active: true)
      end
      expect(user.active_member_of_organisation?(organisation)).to be false
    end

    # REQUEST-LEVEL CACHE GUARD (@active_member_cache). Two calls for the same
    # org must hit the DB once; the second is served from the per-instance memo.
    # Mutants that remove the memo (`||= ...` -> plain query) or re-init the
    # hash on every call (`@active_member_cache ||= {}` -> `= {}`) fire a second
    # membership query and reden this. A fresh instance guarantees an empty memo.
    it 'fires exactly one membership query for two calls (memoised)' do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, active: true)
      end
      fresh = User.find(user.id)

      sql = captured_sql do
        fresh.active_member_of_organisation?(organisation)
        fresh.active_member_of_organisation?(organisation)
      end

      membership_queries = sql.grep(/FROM "memberships"/i)
      expect(membership_queries.size).to eq(1)
    end
  end

  describe '#active_memberships' do
    let(:user) { create(:user) }
    let(:organisation1) { create(:organisation) }
    let(:organisation2) { create(:organisation) }

    before do
      ActsAsTenant.with_tenant(organisation1) do
        create(:membership, user: user, organisation: organisation1, active: true)
      end
      ActsAsTenant.with_tenant(organisation2) do
        create(:membership, user: user, organisation: organisation2, active: false)
      end
    end

    it 'returns only active memberships' do
      expect(user.active_memberships.count).to eq(1)
      expect(user.active_memberships.first.organisation).to eq(organisation1)
    end

    # Spans organisations on purpose: User is not tenant-scoped, so a second
    # ACTIVE membership in another org must ALSO come back. Pins that no stray
    # tenant scope ever narrows active_memberships to a single org (while still
    # excluding the inactive one).
    it 'returns active memberships across multiple organisations' do
      org3 = create(:organisation)
      ActsAsTenant.with_tenant(org3) do
        create(:membership, user: user, organisation: org3, active: true)
      end
      # Compare organisation_id (a loaded column) rather than .organisation (one
      # lazy query per row -> Prosopite N+1, and irrelevant to this assertion).
      expect(user.active_memberships.map(&:organisation_id)).to contain_exactly(organisation1.id, org3.id)
    end
  end

  describe '#active_organisations' do
    let(:user) { create(:user) }
    let(:organisation1) { create(:organisation) }
    let(:organisation2) { create(:organisation) }

    before do
      ActsAsTenant.with_tenant(organisation1) do
        create(:membership, user: user, organisation: organisation1, active: true)
      end
      ActsAsTenant.with_tenant(organisation2) do
        create(:membership, user: user, organisation: organisation2, active: false)
      end
    end

    it 'returns only organisations with active memberships' do
      expect(user.active_organisations.count).to eq(1)
      expect(user.active_organisations).to include(organisation1)
      expect(user.active_organisations).not_to include(organisation2)
    end

    # Cross-tenant span, mirror of active_memberships: two active memberships in
    # different orgs yield BOTH organisations through the merge(Membership.active)
    # join, while the inactive one stays out.
    it 'returns active organisations across multiple memberships' do
      org3 = create(:organisation)
      ActsAsTenant.with_tenant(org3) do
        create(:membership, user: user, organisation: org3, active: true)
      end
      expect(user.active_organisations).to contain_exactly(organisation1, org3)
    end
  end

  describe '#role_in_organisation' do
    let(:user) { create(:user) }
    let(:organisation) { create(:organisation) }
    let(:role) do
      ActsAsTenant.with_tenant(organisation) do
        create(:role, organisation: organisation)
      end
    end

    context 'when user has a role in the organisation' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: user, organisation: organisation, role: role)
        end
      end

      it 'returns the role' do
        ActsAsTenant.with_tenant(organisation) do
          expect(user.role_in_organisation(organisation)).to eq(role)
        end
      end

      # id-or-object coercion (the is_a?(Organisation) branch). Both forms must
      # resolve to the same role.
      it 'accepts the organisation id as well as the object' do
        ActsAsTenant.with_tenant(organisation) do
          expect(user.role_in_organisation(organisation.id)).to eq(role)
        end
      end
    end

    context 'when user does not have a role in the organisation' do
      it 'returns nil' do
        expect(user.role_in_organisation(organisation)).to be_nil
      end
    end

    # A membership WHOSE role is nil (role_id NULL — bypassing the after_create
    # default-role assignment via update_column) is a DIFFERENT path from "no
    # membership": find/detect succeeds, but `membership&.role` is nil. A mutant
    # `membership&.role` -> `membership` would return the membership object and
    # redden the be_nil. NOTE: create(:membership, role: nil) alone does NOT
    # produce this — Membership#assign_default_role assigns the org default role.
    it 'returns nil for a membership whose role is nil' do
      ActsAsTenant.with_tenant(organisation) do
        membership = create(:membership, user: user, organisation: organisation, role: role)
        membership.update_column(:role_id, nil) # must skip assign_default_role
        expect(User.find(user.id).role_in_organisation(organisation)).to be_nil
      end
    end

    # CROSS-ORG ISOLATION: a role in another org must not leak. The "no role"
    # case (no membership) cannot catch find_by(organisation_id:) -> find_by
    # (first membership). Run WITHOUT a current tenant on purpose: the correct
    # lookup finds no membership in `organisation` and never loads a role; a
    # mutant that drops the organisation_id filter would fetch the foreign
    # membership and try to load its role with no tenant set -> blows up / wrong
    # role. Either way it reddens.
    it 'returns nil for an org the user is not in, despite a membership elsewhere' do
      other = create(:organisation)
      ActsAsTenant.with_tenant(other) do
        create(:membership, user: user, organisation: other) # gets other's default role
      end
      expect(User.find(user.id).role_in_organisation(organisation)).to be_nil
    end

    # REQUEST-LEVEL CACHE GUARD (@role_cache), positive path. Two calls for the
    # same org must hit the DB once. Mutants that weaken the memo
    # (`@role_cache ||= {}` -> `= {}`, dropping the `return ... if key?` line)
    # fire a second membership query and reden this.
    it 'fires exactly one membership query for two calls (memoised)' do
      # Wrapped in a tenant because resolving membership.role touches the
      # acts_as_tenant Role model (require_tenant). The membership lookup itself
      # is cross-tenant and unaffected; only FROM "memberships" is counted.
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, role: role)
        fresh = User.find(user.id)

        sql = captured_sql do
          fresh.role_in_organisation(organisation)
          fresh.role_in_organisation(organisation)
        end

        expect(sql.grep(/FROM "memberships"/i).size).to eq(1)
      end
    end

    # The memo caches a nil result too (the method uses `@role_cache.key?` rather
    # than `||=` precisely so "no role" is not re-queried every call). A mutant
    # that switches to `@role_cache[org_id] ||= ...` would re-run the lookup
    # because nil is falsy — caught here by the second call firing no query.
    it 'caches a nil result without re-querying' do
      fresh = User.find(user.id) # no membership in organisation

      results = []
      sql = captured_sql do
        results << fresh.role_in_organisation(organisation)
        results << fresh.role_in_organisation(organisation)
      end

      expect(results).to eq([nil, nil])
      expect(sql.grep(/FROM "memberships"/i).size).to eq(1)
    end

    # The loaded?-branch: when the memberships association is already in memory,
    # the role is resolved with an in-memory `detect`, NOT a fresh find_by. Pins
    # the detect-vs-find_by split (iron rule of this slice) — dropping it would
    # fire a membership query inside the measured block.
    it 'uses the in-memory association when memberships are already loaded' do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, role: role)
        fresh = User.find(user.id)
        fresh.memberships.load # force memberships.loaded? => true (query is outside the measure)

        sql = captured_sql { fresh.role_in_organisation(organisation) }

        expect(sql.grep(/FROM "memberships"/i)).to be_empty
        expect(fresh.role_in_organisation(organisation)).to eq(role)
      end
    end
  end
end
