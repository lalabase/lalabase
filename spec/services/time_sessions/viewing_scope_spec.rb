# frozen_string_literal: true

require 'rails_helper'

# What: TimeSessions::ViewingScope, the one owner of the "all / own / none" tier
#       for a user's view on a project's booked time.
# Type: Service spec.
# Why:  ProjectPolicy#area_access?(:time_sessions) answers "may see time" as
#       can_view_own || can_view_all and cannot tell the two apart. Every report
#       over booked time (the chat tool, the subject hours chip) needs the tier,
#       and it must be fail-closed: no persisted permission row means :none, not
#       the model's can_view_own default on an unsaved row.
RSpec.describe TimeSessions::ViewingScope do
  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:user)         { create(:user) }
  let(:other_user)   { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
    create(:membership, user: other_user, organisation: organisation)
  end

  after { ActsAsTenant.current_tenant = nil }

  let!(:own_session)   { create(:time_session, project: project, organisation: organisation, creator: user, duration: 30) }
  let!(:other_session) { create(:time_session, project: project, organisation: organisation, creator: other_user, duration: 45) }

  def scope
    described_class.call(user: user, project: project)
  end

  def visible_ids
    scope.apply(project.time_sessions).pluck(:id)
  end

  context 'without a persisted permission row' do
    it 'is :none and yields an empty relation (fail-closed, unlike the unsaved-row default)' do
      expect(scope.tier).to eq(:none)
      expect(scope).to be_none
      expect(visible_ids).to be_empty
    end
  end

  context 'with can_view_own only' do
    before { create(:time_session_permission, user: user, project: project, can_view_own: true, can_view_all: false) }

    # THE case the area gate cannot separate. Mutation probe: make #apply return
    # the relation untouched for :own and this example turns red.
    it 'is :own and narrows to the user\'s own sessions' do
      expect(scope.tier).to eq(:own)
      expect(visible_ids).to contain_exactly(own_session.id)
      expect(visible_ids).not_to include(other_session.id)
    end
  end

  context 'with can_view_all' do
    before { create(:time_session_permission, user: user, project: project, can_view_own: false, can_view_all: true) }

    it 'is :all and leaves the relation untouched' do
      expect(scope.tier).to eq(:all)
      expect(visible_ids).to contain_exactly(own_session.id, other_session.id)
    end
  end

  # Drittreview: the precedence (can_view_all before can_view_own) was only
  # covered via consumer specs; this pins it at the owner. Mutation probe: swap
  # the two checks in #resolve_tier and this example turns red (:own).
  context 'with both can_view_own and can_view_all' do
    before { create(:time_session_permission, user: user, project: project, can_view_own: true, can_view_all: true) }

    it 'is :all (view_all wins over view_own)' do
      expect(scope.tier).to eq(:all)
      expect(visible_ids).to contain_exactly(own_session.id, other_session.id)
    end
  end

  context 'with a row that grants neither' do
    before { create(:time_session_permission, user: user, project: project, can_view_own: false, can_view_all: false) }

    it 'is :none' do
      expect(scope.tier).to eq(:none)
      expect(visible_ids).to be_empty
    end
  end

  # Zweitreview F4: the area gate (ProjectPolicy#area_access?) refuses inactive
  # members, so the one owner of the tier rule must too — a stale permission row
  # or admin role behind a deactivated membership grants nothing.
  context 'with a deactivated membership' do
    before { user.memberships.find_by(organisation: organisation).update!(active: false) }

    it 'is :none despite a can_view_all permission row' do
      create(:time_session_permission, user: user, project: project, can_view_all: true)
      expect(scope.tier).to eq(:none)
      expect(visible_ids).to be_empty
    end

    it 'is :none despite an account_admin role' do
      admin_role = create(:role, organisation: organisation, title: 'account_admin')
      user.memberships.find_by(organisation: organisation).update!(role: admin_role)
      expect(scope.tier).to eq(:none)
    end
  end

  context 'as account admin of the organisation' do
    before do
      admin_role = create(:role, organisation: organisation, title: 'account_admin')
      user.memberships.find_by(organisation: organisation).update!(role: admin_role)
    end

    it 'is :all without any permission row' do
      expect(scope.tier).to eq(:all)
      expect(visible_ids).to contain_exactly(own_session.id, other_session.id)
    end
  end

  it 'is :none for a missing user or project' do
    expect(described_class.call(user: nil, project: project).tier).to eq(:none)
    expect(described_class.call(user: user, project: nil).tier).to eq(:none)
  end

  it 'never widens: applying to a relation of another project returns nothing extra' do
    create(:time_session_permission, user: user, project: project, can_view_all: true)
    other_project = create(:project, organisation: organisation)
    foreign = create(:time_session, project: other_project, organisation: organisation, creator: user)

    expect(scope.apply(project.time_sessions).pluck(:id)).not_to include(foreign.id)
  end

  # S0 of the Projektzeiten rebuild (doc/projektzeiten_tabelle_plan.md): the same
  # tier rule, asked for a whole organisation in ONE query. TimeSessionPolicy::Scope
  # carried a second, hand-written copy of it that knew nothing about deactivated
  # memberships; these examples pin the two entry points to one rule so the copy
  # can go.
  describe '.for_organisation' do
    let(:project_all)  { create(:project, organisation: organisation) }
    let(:project_none) { create(:project, organisation: organisation) }

    let!(:all_own)   { create(:time_session, project: project_all, organisation: organisation, creator: user, duration: 10) }
    let!(:all_other) { create(:time_session, project: project_all, organisation: organisation, creator: other_user, duration: 15) }
    let!(:none_own)  { create(:time_session, project: project_none, organisation: organisation, creator: user, duration: 20) }

    before do
      create(:time_session_permission, user: user, project: project, can_view_own: true, can_view_all: false)
      create(:time_session_permission, user: user, project: project_all, can_view_all: true)
    end

    def org_scope
      described_class.for_organisation(user: user, organisation: organisation)
    end

    # Parity is the whole point of the slice: one rule, two entry points. Both
    # sides are pinned to the LITERAL tier, not just to each other -- two equally
    # wrong answers would pass a comparison. One project per example, because a
    # loop over the single-project path is an N+1 by construction (that is why
    # .for_organisation exists) and Prosopite would rightly say so.
    it 'reads a can_view_own project the same way .call does' do
      expect(org_scope.tier_for(project.id)).to eq(:own)
      expect(described_class.call(user: user, project: project).tier).to eq(:own)
    end

    it 'reads a can_view_all project the same way .call does' do
      expect(org_scope.tier_for(project_all.id)).to eq(:all)
      expect(described_class.call(user: user, project: project_all).tier).to eq(:all)
    end

    it 'reads a project without a permission row the same way .call does' do
      expect(org_scope.tier_for(project_none.id)).to eq(:none)
      expect(described_class.call(user: user, project: project_none).tier).to eq(:none)
    end

    it 'narrows one relation across projects of three different tiers' do
      expect(org_scope.apply(TimeSession.all).pluck(:id))
        .to contain_exactly(own_session.id, all_own.id, all_other.id)
    end

    it 'is :none for a project without a row, and for an id it never saw (fail-closed)' do
      expect(org_scope.tier_for(project_none.id)).to eq(:none)
      expect(org_scope.tier_for(SecureRandom.uuid)).to eq(:none)
    end

    # The reason this method exists: the policy used to run two pluck queries and
    # a probe per resolve. One row set answers for every project.
    it 'reads the permission rows once, not once per project' do
      statements = capture_sql { org_scope.apply(TimeSession.all).load }

      expect(statements.grep(/FROM "time_session_permissions"/).size).to eq(1)
    end

    context 'as account admin of the organisation' do
      before do
        admin_role = create(:role, organisation: organisation, title: 'account_admin')
        user.memberships.find_by(organisation: organisation).update!(role: admin_role)
      end

      it 'is :all everywhere and leaves the relation untouched' do
        expect(org_scope.tier_for(project_none.id)).to eq(:all)
        expect(org_scope.apply(TimeSession.all).pluck(:id))
          .to contain_exactly(own_session.id, other_session.id, all_own.id, all_other.id, none_own.id)
      end
    end

    context 'with a deactivated membership' do
      before { user.memberships.find_by(organisation: organisation).update!(active: false) }

      it 'yields nothing, permission rows notwithstanding' do
        expect(org_scope.tier_for(project_all.id)).to eq(:none)
        expect(org_scope.apply(TimeSession.all)).to be_empty
      end

      it 'yields nothing, an account_admin role notwithstanding' do
        admin_role = create(:role, organisation: organisation, title: 'account_admin')
        user.memberships.find_by(organisation: organisation).update!(role: admin_role)

        expect(org_scope.apply(TimeSession.all)).to be_empty
      end
    end

    # The other side grants EVERYTHING, so what keeps the foreign row out is this
    # object and not acts_as_tenant: the relation is read without a tenant.
    it 'never reaches into another organisation, even where the user is admin there' do
      foreign_org = create(:organisation)
      foreign_session = ActsAsTenant.with_tenant(foreign_org) do
        foreign_project = create(:project, organisation: foreign_org)
        foreign_admin_role = create(:role, organisation: foreign_org, title: 'account_admin')
        create(:membership, user: user, organisation: foreign_org, role: foreign_admin_role)
        create(:time_session_permission, user: user, project: foreign_project, can_view_all: true)
        create(:time_session, project: foreign_project, organisation: foreign_org, creator: user, duration: 99)
      end

      scope = org_scope
      ids = ActsAsTenant.without_tenant { scope.apply(TimeSession.all).pluck(:id) }

      expect(ids).to include(own_session.id)
      expect(ids).not_to include(foreign_session.id)
      # Both exits, not just the one the list happens to use: a caller that asks
      # per project must not learn a tier for a project of another organisation.
      expect(scope.tier_for(foreign_session.project_id)).to eq(:none)
    end

    # The list's project select, the menu gate and the booking form ask these
    # two, so that "which projects do I see here" has the same owner as "which
    # rows do I see" (doc/zeiten_eine_liste_plan.md, S4).
    describe '#projects' do
      let!(:project_blank) do
        create(:project, organisation: organisation).tap do |blank|
          create(:time_session_permission, user: user, project: blank, can_view_own: false, can_view_all: false)
        end
      end

      it 'names the projects at :all and :own, not the ones at :none' do
        expect(org_scope.projects).to contain_exactly(project, project_all)
      end

      it 'names every project of the organisation for an account admin' do
        admin_role = create(:role, organisation: organisation, title: 'account_admin')
        user.memberships.find_by(organisation: organisation).update!(role: admin_role)

        expect(org_scope.projects).to contain_exactly(project, project_all, project_none, project_blank)
      end

      it 'names nothing behind a deactivated membership' do
        user.memberships.find_by(organisation: organisation).update!(active: false)

        expect(org_scope.projects).to be_empty
      end

      it 'never names a project of another organisation, admin there or not' do
        foreign_org = create(:organisation)
        foreign_project = ActsAsTenant.with_tenant(foreign_org) do
          create(:project, organisation: foreign_org).tap do |fp|
            foreign_admin_role = create(:role, organisation: foreign_org, title: 'account_admin')
            create(:membership, user: user, organisation: foreign_org, role: foreign_admin_role)
            create(:time_session_permission, user: user, project: fp, can_view_all: true)
          end
        end

        ids = ActsAsTenant.without_tenant { org_scope.projects.pluck(:id) }
        expect(ids).to include(project.id)
        expect(ids).not_to include(foreign_project.id)
      end
    end

    describe '#sees_anything?' do
      it 'is true with a project at :own or :all' do
        expect(org_scope.sees_anything?).to be true
      end

      it 'is false without rows, and with a row that grants nothing' do
        expect(described_class.for_organisation(user: other_user, organisation: organisation).sees_anything?).to be false

        create(:time_session_permission, user: other_user, project: project, can_view_own: false, can_view_all: false)
        expect(described_class.for_organisation(user: other_user, organisation: organisation).sees_anything?).to be false
      end

      it 'is true for an account admin without any row' do
        admin_role = create(:role, organisation: organisation, title: 'account_admin')
        other_user.memberships.find_by(organisation: organisation).update!(role: admin_role)

        expect(described_class.for_organisation(user: other_user, organisation: organisation).sees_anything?).to be true
      end

      it 'is false behind a deactivated membership' do
        user.memberships.find_by(organisation: organisation).update!(active: false)

        expect(org_scope.sees_anything?).to be false
      end
    end

    it 'yields nothing without a user or without an organisation' do
      expect(described_class.for_organisation(user: nil, organisation: organisation).apply(TimeSession.all)).to be_empty
      expect(described_class.for_organisation(user: user, organisation: nil).apply(TimeSession.all)).to be_empty
    end
  end
end
