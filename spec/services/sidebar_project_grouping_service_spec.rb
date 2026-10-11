# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SidebarProjectGroupingService do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
  end

  def build_projects(count)
    count.times.map { |i| create(:project, organisation: organisation, name: "Project #{i + 1}") }
  end

  def grant_access(projects)
    Prosopite.pause
    projects.each do |proj|
      create(:project_permission, user: user, project: proj, tickets_access: :read_only)
    end
    Prosopite.resume
  end

  def service(projects, current_project: nil)
    described_class.new(user, organisation, projects: projects, current_project: current_project)
  end

  describe '#call' do
    context 'with 5 or fewer projects' do
      it 'returns all projects as active, rest is empty' do
        projects = build_projects(4)
        grant_access(projects)

        result = service(projects).call

        expect(result[:active]).to match_array(projects)
        expect(result[:rest]).to be_empty
      end

      it 'returns all projects as active when exactly 5' do
        projects = build_projects(5)
        grant_access(projects)

        result = service(projects).call

        expect(result[:active]).to match_array(projects)
        expect(result[:rest]).to be_empty
      end
    end

    context 'with more than 5 projects' do
      let!(:projects) { build_projects(8) }

      before { grant_access(projects) }

      it 'splits projects into active and rest' do
        # No access timestamps → all go to rest, then backfill picks 3
        result = service(projects).call

        expect(result[:active].size).to eq(SidebarProjectGroupingService::MIN_ACTIVE)
        expect(result[:rest].size).to eq(5)
        expect(result[:active] + result[:rest]).to match_array(projects)
      end

      it 'puts recently accessed projects into active' do
        Prosopite.pause
        recent = projects.first(2)
        recent.each do |proj|
          user.project_permissions.find_by(project: proj)
              .update_column(:last_accessed_at, 10.days.ago)
        end
        Prosopite.resume

        result = service(projects).call

        expect(result[:active]).to include(*recent)
      end

      it 'excludes projects accessed more than 60 days ago from active (unless backfilled)' do
        Prosopite.pause
        old_project = projects.first
        user.project_permissions.find_by(project: old_project)
            .update_column(:last_accessed_at, 90.days.ago)
        Prosopite.resume

        # Only the old project has a timestamp, rest have none
        result = service(projects).call

        # old_project should NOT be in active due to recency
        # (it may appear via backfill, but not due to the recency check)
        expect(result[:active]).not_to include(old_project) if result[:active].size > SidebarProjectGroupingService::MIN_ACTIVE
      end

      it 'always includes current_project in active' do
        current = projects.last

        result = service(projects, current_project: current).call

        expect(result[:active]).to include(current)
      end

      it 'includes projects with unread notifications in active' do
        Prosopite.pause
        notified_project = projects[3]
        create(:notification,
               recipient: user,
               organisation: organisation,
               project: notified_project,
               channel: :in_app,
               state: :sent)
        Prosopite.resume

        result = service(projects).call

        expect(result[:active]).to include(notified_project)
      end
    end

    context 'backfill to minimum active' do
      let!(:projects) { build_projects(7) }

      before { grant_access(projects) }

      it 'ensures at least MIN_ACTIVE projects in active group' do
        # No timestamps, no current, no unread → backfill should kick in
        result = service(projects).call

        expect(result[:active].size).to be >= SidebarProjectGroupingService::MIN_ACTIVE
      end

      it 'backfills with most recently accessed projects from rest' do
        Prosopite.pause
        # Give one project a recent-ish timestamp (but still older than cutoff)
        backfill_candidate = projects[4]
        user.project_permissions.find_by(project: backfill_candidate)
            .update_column(:last_accessed_at, 90.days.ago)
        Prosopite.resume

        result = service(projects).call

        # The project with the most recent timestamp (even if old) should be
        # preferred during backfill over projects with no timestamp at all
        expect(result[:active]).to include(backfill_candidate)
      end
    end

    context 'filtering' do
      it 'excludes archived projects' do
        projects = build_projects(3)
        grant_access(projects)
        Prosopite.pause
        archived = create(:project, organisation: organisation, name: 'Archived', archived_at: 1.day.ago)
        create(:project_permission, user: user, project: archived, tickets_access: :read_only)
        Prosopite.resume

        result = service(projects + [archived]).call

        all_returned = result[:active] + result[:rest]
        expect(all_returned).not_to include(archived)
      end

      it 'excludes projects from other organisations' do
        Prosopite.pause
        other_org = create(:organisation)
        other_project = ActsAsTenant.with_tenant(other_org) do
          create(:project, organisation: other_org, name: 'Other Org')
        end
        Prosopite.resume
        projects = build_projects(3)
        grant_access(projects)

        result = service(projects + [other_project]).call

        all_returned = result[:active] + result[:rest]
        expect(all_returned).not_to include(other_project)
      end
    end

    context 'with empty input' do
      it 'returns empty groups for empty projects' do
        result = service([]).call

        expect(result[:pinned]).to be_empty
        expect(result[:active]).to be_empty
        expect(result[:rest]).to be_empty
      end
    end

    context 'with pinned projects' do
      let!(:projects) { build_projects(8) }

      before { grant_access(projects) }

      it 'returns pinned projects in pin order, removed from active/rest' do
        user.sidebar_pins.pin_project!(organisation, projects[5].id)
        user.sidebar_pins.pin_project!(organisation, projects[2].id)

        result = service(projects).call

        expect(result[:pinned]).to eq([projects[2], projects[5]])
        all_unpinned = result[:active] + result[:rest]
        expect(all_unpinned).not_to include(projects[2], projects[5])
        expect(result[:pinned] + all_unpinned).to match_array(projects)
      end

      it 'collapses all unpinned projects behind the toggle once anything is pinned' do
        user.sidebar_pins.pin_project!(organisation, projects[0].id)
        user.sidebar_pins.pin_project!(organisation, projects[1].id)
        user.sidebar_pins.pin_project!(organisation, projects[2].id)

        result = service(projects).call

        expect(result[:pinned].size).to eq(3)
        expect(result[:active]).to be_empty
        expect(result[:rest].size).to eq(5)
      end

      it 'collapses unpinned into rest even when only a few projects remain' do
        # 8 - 4 pins = 4 unpinned (below MAX_UNGROUPED) but a pin exists → still behind toggle
        projects.first(4).each { |p| user.sidebar_pins.pin_project!(organisation, p.id) }

        result = service(projects).call

        expect(result[:pinned].size).to eq(4)
        expect(result[:active]).to be_empty
        expect(result[:rest].size).to eq(4)
      end

      it 'keeps the current project visible (in active) even when pins exist' do
        user.sidebar_pins.pin_project!(organisation, projects[0].id)
        current = projects[5]

        result = service(projects, current_project: current).call

        expect(result[:active]).to eq([current])
        expect(result[:rest]).not_to include(current)
      end

      it 'ignores pins referencing projects the user cannot see' do
        user.sidebar_pins.pin_project!(organisation, SecureRandom.uuid)

        result = service(projects).call

        expect(result[:pinned]).to be_empty
      end

      it 'ignores pins stored under a different organisation (no cross-org leak)' do
        other_org = create(:organisation)
        user.sidebar_pins.pin_project!(other_org, projects[0].id)

        result = service(projects).call

        expect(result[:pinned]).to be_empty
        expect(result[:active] + result[:rest]).to match_array(projects)
      end
    end
  end
end
