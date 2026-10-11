# frozen_string_literal: true

# Current.project_policy is a request-scoped memo (see app/models/current.rb): the dashboard
# render builds ~9-15 ProjectPolicy instances per page, so one instance per (user, project) per
# request is reused. These pin the memo identity AND that reset clears it, so a stubbed/real
# policy can never leak across authorization contexts.
require 'rails_helper'

RSpec.describe Current do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after do
    ActsAsTenant.current_tenant = nil
    Current.reset
  end

  # The project set behind every unread count (Notification.source_projects_for). The layout asks
  # for the count three times per page (sidebar link, count frame, mobile nav), and for a member
  # with local project rights each resolution is nine queries.
  describe '.notification_source_projects' do
    it 'resolves project access once per (user, organisation, area) and reuses it' do
      expect(AccessCheck::ProjectAccessService).to receive(:accessible_projects)
        .with(user, organisation, area: nil).once.and_call_original
      expect(AccessCheck::ProjectAccessService).to receive(:accessible_projects)
        .with(user, organisation, area: :tickets).once.and_call_original

      2.times { Notification.source_projects_for(user, organisation) }
      2.times { Notification.source_projects_for(user, organisation, area: :tickets) }
    end

    it 'resolves again for another organisation and for another user' do
      other_org = create(:organisation)
      other_user = create(:user)
      expect(AccessCheck::ProjectAccessService).to receive(:accessible_projects).exactly(3).times.and_call_original

      Notification.source_projects_for(user, organisation)
      Notification.source_projects_for(user, other_org)
      Notification.source_projects_for(other_user, organisation)
    end

    it 'is cleared by reset so a later request sees changed access' do
      expect(AccessCheck::ProjectAccessService).to receive(:accessible_projects).twice.and_call_original

      Notification.source_projects_for(user, organisation)
      Current.reset
      Notification.source_projects_for(user, organisation)
    end
  end

  describe '.project_policy' do
    it 'builds one ProjectPolicy per (user, project) and reuses it' do
      expect(ProjectPolicy).to receive(:new).with(user, project).once.and_call_original

      first = Current.project_policy(user, project)
      second = Current.project_policy(user, project)

      expect(first).to be_a(ProjectPolicy)
      expect(second).to be(first)
    end

    it 'builds distinct instances for different projects' do
      other = create(:project, organisation: organisation)
      expect(Current.project_policy(user, project)).not_to be(Current.project_policy(user, other))
    end

    it 'is cleared by reset so nothing leaks across requests' do
      before_reset = Current.project_policy(user, project)
      Current.reset
      expect(Current.project_policy(user, project)).not_to be(before_reset)
    end
  end

  # The org-overview "any project" permission primitive: a widget that aggregates across all of a
  # viewer's projects is visible if at least ONE project grants the area+action. It must reuse the
  # exact per-project #area_access? (no duplicated rules), short-circuit on admins and on the first
  # match, and memoize per (user, org, area, action).
  describe '.area_access_anywhere?' do
    it 'returns false without a user' do
      expect(Current.area_access_anywhere?(nil, organisation, :tickets, :read)).to be false
    end

    it 'short-circuits to true for an account admin (no project policy built)' do
      allow(user).to receive(:account_admin_in?).with(organisation).and_return(true)
      expect(ProjectPolicy::Scope).not_to receive(:new)

      expect(Current.area_access_anywhere?(user, organisation, :tickets, :read)).to be true
    end

    context 'non-admin' do
      let(:policy) { instance_double(ProjectPolicy) }

      before do
        allow(user).to receive(:account_admin_in?).with(organisation).and_return(false)
        scope = instance_double(ProjectPolicy::Scope, resolve: accessible_projects)
        allow(ProjectPolicy::Scope).to receive(:new).and_return(scope)
        allow(ProjectPolicy).to receive(:new).with(user, project).and_return(policy)
      end

      context 'with at least one accessible project granting the area+action' do
        let(:accessible_projects) { [project] }
        before { allow(policy).to receive(:area_access?).with(:tickets, :read).and_return(true) }

        it 'returns true' do
          expect(Current.area_access_anywhere?(user, organisation, :tickets, :read)).to be true
        end

        it 'memoizes (resolves the permission only once across repeated calls)' do
          expect(policy).to receive(:area_access?).with(:tickets, :read).once.and_return(true)

          2.times { expect(Current.area_access_anywhere?(user, organisation, :tickets, :read)).to be true }
        end
      end

      context 'when no accessible project grants the area+action' do
        let(:accessible_projects) { [project] }
        before { allow(policy).to receive(:area_access?).with(:tickets, :read).and_return(false) }

        it 'returns false' do
          expect(Current.area_access_anywhere?(user, organisation, :tickets, :read)).to be false
        end
      end

      context 'when the user has no accessible projects' do
        let(:accessible_projects) { [] }

        it 'returns false' do
          expect(Current.area_access_anywhere?(user, organisation, :tickets, :read)).to be false
        end
      end
    end
  end
end
