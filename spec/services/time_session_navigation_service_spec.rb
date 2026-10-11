# frozen_string_literal: true

require 'rails_helper'

# What: TimeSessionNavigationService, the thin door the time list and its menu
#       entry go through: may this person open the list at all, which projects
#       may they filter by, and in which projects may they book.
# Type: Service spec.
# Why:  The first two answers are TimeSessions::ViewingScope's (one owner of
#       the "all / own / none" rule, doc/zeiten_eine_liste_plan.md S4); the
#       service used to carry its own copy that knew neither the viewing flags
#       (a row granting nothing still listed the project) nor deactivated
#       memberships. The third is the booking flag, can_create_own.
RSpec.describe TimeSessionNavigationService do
  let(:organisation) { create(:organisation) }
  let(:other_org)    { create(:organisation) }
  let(:member_role)  { create(:role, organisation: organisation) }
  let(:admin_role)   { create(:role, organisation: organisation, title: 'account_admin') }
  let(:user)         { create(:user) }
  let(:service)      { described_class.new(user, organisation) }

  let(:project)      { create(:project, organisation: organisation, name: 'Beta') }
  let(:project_two)  { create(:project, organisation: organisation, name: 'Alpha') }
  let!(:foreign_project) { ActsAsTenant.with_tenant(other_org) { create(:project, organisation: other_org) } }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def join(role: member_role, active: true)
    create(:membership, user: user, organisation: organisation, role: role, active: active)
  end

  def grant(target_project, **flags)
    create(:time_session_permission, user: user, project: target_project, **flags)
  end

  describe '#can_show_all_time_sessions_menu?' do
    it 'is false without a user or without an organisation' do
      expect(described_class.new(nil, organisation).can_show_all_time_sessions_menu?).to be false
      expect(described_class.new(user, nil).can_show_all_time_sessions_menu?).to be false
    end

    it 'is false for someone who is not a member' do
      grant(project, can_view_all: true)

      expect(service.can_show_all_time_sessions_menu?).to be false
    end

    it 'is true for an account admin without any permission row' do
      join(role: admin_role)

      expect(service.can_show_all_time_sessions_menu?).to be true
    end

    it 'is true with can_view_own or can_view_all in one project' do
      join
      grant(project, can_view_own: true, can_view_all: false)

      expect(service.can_show_all_time_sessions_menu?).to be true
    end

    it 'is false with a row that grants neither viewing flag' do
      join
      grant(project, can_view_own: false, can_view_all: false, can_create_own: true)

      expect(service.can_show_all_time_sessions_menu?).to be false
    end

    it 'is false with a viewing row in another organisation only' do
      join
      ActsAsTenant.with_tenant(other_org) { grant(foreign_project, can_view_all: true) }

      expect(service.can_show_all_time_sessions_menu?).to be false
    end

    it 'is false behind a deactivated membership, admin role or not' do
      join(role: admin_role, active: false)
      grant(project, can_view_all: true)

      expect(service.can_show_all_time_sessions_menu?).to be false
    end
  end

  describe '#accessible_projects_with_time_sessions' do
    it 'lists every project of the organisation, by name, for an account admin' do
      join(role: admin_role)
      project
      project_two

      expect(service.accessible_projects_with_time_sessions.map(&:name)).to eq(%w[Alpha Beta])
    end

    it 'lists only the projects with a viewing flag, by name' do
      join
      grant(project, can_view_own: true)
      grant(project_two, can_view_all: true)
      grant(create(:project, organisation: organisation, name: 'Gamma'), can_view_own: false, can_view_all: false)

      expect(service.accessible_projects_with_time_sessions.map(&:name)).to eq(%w[Alpha Beta])
    end

    it 'lists nothing without rows, behind a deactivated membership, or from another organisation' do
      join(active: false)
      grant(project, can_view_all: true)
      ActsAsTenant.with_tenant(other_org) { grant(foreign_project, can_view_all: true) }

      expect(service.accessible_projects_with_time_sessions).to be_empty
    end
  end

  describe '#bookable_projects' do
    it 'lists every project of the organisation, by name, for an account admin' do
      join(role: admin_role)
      project
      project_two

      expect(service.bookable_projects.map(&:name)).to eq(%w[Alpha Beta])
    end

    it 'lists only the projects with can_create_own, viewing flags notwithstanding' do
      join
      grant(project, can_create_own: true, can_view_own: false, can_view_all: false)
      grant(project_two, can_create_own: false, can_view_all: true)

      expect(service.bookable_projects.map(&:name)).to eq(%w[Beta])
    end

    it 'lists nothing behind a deactivated membership or from another organisation' do
      join(active: false)
      grant(project, can_create_own: true)
      ActsAsTenant.with_tenant(other_org) { grant(foreign_project, can_create_own: true) }

      expect(service.bookable_projects).to be_empty
    end

    it 'lists nothing without a user' do
      expect(described_class.new(nil, organisation).bookable_projects).to be_empty
    end
  end
end
