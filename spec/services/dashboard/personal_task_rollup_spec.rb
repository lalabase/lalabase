# frozen_string_literal: true

require 'rails_helper'

# Cross-org roll-up of the user's OWN open personal to-dos. Pins the load-bearing behaviour:
# user-privacy (never another user's to-dos, even in a shared org), membership gating, open-only,
# and per-org grouping.
RSpec.describe Dashboard::PersonalTaskRollup do
  subject(:rollup) { described_class.new(user: user) }

  let(:user) { create(:user) }
  let(:org_a) { create(:organisation) }
  let(:org_b) { create(:organisation) }

  after { ActsAsTenant.current_tenant = nil }

  def member(target_user, org, active: true)
    role = create(:role, organisation: org)
    create(:membership, user: target_user, organisation: org, role: role, active: active)
  end

  # account_admin in the org — used to prove there is NO admin bypass in the roll-up.
  def admin_member(target_user, org)
    role = create(:role, title: 'account_admin', organisation: org)
    create(:membership, user: target_user, organisation: org, role: role, active: true)
  end

  # All task titles the roll-up would surface for `user`, flattened across org slices.
  def rolled_up_titles
    rollup.slices.flat_map { |_organisation, tasks| tasks.map(&:title) }
  end

  it "rolls up the user's own open to-dos per org, only orgs with items" do
    ActsAsTenant.with_tenant(org_a) do
      member(user, org_a)
      create(:personal_task, user: user, organisation: org_a, title: 'A1')
      create(:personal_task, user: user, organisation: org_a, title: 'A2')
    end
    ActsAsTenant.with_tenant(org_b) { member(user, org_b) } # member, nothing open

    expect(rollup.slices.map { |organisation, _tasks| organisation }).to contain_exactly(org_a)
    expect(rollup.slices.first.last.map(&:title)).to contain_exactly('A1', 'A2')
    expect(rollup.total).to eq(2)
    expect(rollup.any?).to be(true)
  end

  it 'excludes completed to-dos' do
    ActsAsTenant.with_tenant(org_a) do
      member(user, org_a)
      create(:personal_task, user: user, organisation: org_a, title: 'open one')
      create(:personal_task, :done, user: user, organisation: org_a, title: 'done one')
    end

    expect(rollup.total).to eq(1)
  end

  describe 'user isolation (the non-negotiable privacy wall)' do
    # Mutation killed: drop `where(user:)` (or invert it) in PersonalTaskRollup. With both members
    # owning a task in the SAME org, the roll-up must surface MINE and never THEIRS — proving
    # inclusion of own AND exclusion of a co-member's in one shot (the old test had the subject own
    # nothing, so it could not tell "scoped correctly" from "happened to be empty").
    it "shows the user's own to-dos and never a co-member's in the same org" do
      other = create(:user)
      ActsAsTenant.with_tenant(org_a) do
        member(user, org_a)
        member(other, org_a)
        create(:personal_task, user: user,  organisation: org_a, title: 'mine')
        create(:personal_task, user: other, organisation: org_a, title: 'theirs')
      end

      expect(rolled_up_titles).to contain_exactly('mine')
      expect(rolled_up_titles).not_to include('theirs')
      expect(rollup.total).to eq(1)
    end

    # Mutation killed: add an `account_admin_in?` bypass to the roll-up. `user` is the org admin and
    # `other` is a plain member with a to-do; an admin must STILL see only their own. The old test
    # used a default-role member, so an admin-bypass mutation would have survived it.
    it 'does not expose a co-member\'s to-dos to an org admin (NO admin bypass)' do
      other = create(:user)
      ActsAsTenant.with_tenant(org_a) do
        admin_member(user, org_a)
        member(other, org_a)
        create(:personal_task, user: user,  organisation: org_a, title: 'admin-own')
        create(:personal_task, user: other, organisation: org_a, title: 'member-private')
      end

      expect(rolled_up_titles).to contain_exactly('admin-own')
      expect(rolled_up_titles).not_to include('member-private')
    end

    # Mutation killed: weaken `with_tenant(org)` (e.g. to without_tenant). The user's OWN tasks must
    # stay grouped under the right org — without per-org tenanting, every slice would show every org's
    # tasks (cross-org bleed of the user's own data).
    it "keeps each org's to-dos in its own slice (no cross-org bleed of the user's own data)" do
      ActsAsTenant.with_tenant(org_a) do
        member(user, org_a)
        create(:personal_task, user: user, organisation: org_a, title: 'in-a')
      end
      ActsAsTenant.with_tenant(org_b) do
        member(user, org_b)
        create(:personal_task, user: user, organisation: org_b, title: 'in-b')
      end

      by_org = rollup.slices.to_h
      expect(by_org[org_a].map(&:title)).to contain_exactly('in-a')
      expect(by_org[org_b].map(&:title)).to contain_exactly('in-b')
    end
  end

  it 'never includes to-dos from an org the user is not a member of' do
    stranger_org = create(:organisation)
    ActsAsTenant.with_tenant(stranger_org) do
      create(:personal_task, user: user, organisation: stranger_org, title: 'orphan')
    end

    expect(rollup.slices).to be_empty
  end

  it 'ignores organisations where the membership is inactive' do
    ActsAsTenant.with_tenant(org_a) do
      member(user, org_a, active: false)
      create(:personal_task, user: user, organisation: org_a, title: 'A1')
    end

    expect(rollup.slices).to be_empty
  end
end
