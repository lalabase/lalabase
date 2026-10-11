# frozen_string_literal: true

require 'rails_helper'

# Cross-org "what needs me" aggregation. The service iterates the user's ACTIVE orgs and, per
# org, runs policy-scoped reads inside that org's tenant. These specs pin the load-bearing
# behaviour: permission correctness per org, tenant isolation, status exclusion, the
# mention/unread distinction (no double-count), partial-empty, and per-org error resilience.
RSpec.describe Dashboard::CrossOrgActionSummary do
  subject(:summary) { described_class.new(user: user, importance: importance) }

  # Core aggregation (membership, tenant isolation, permissions, status exclusion) is
  # importance-independent, so default to the widest level ('all' = the original behaviour). The
  # 'importance levels' block overrides this per context.
  let(:importance) { 'all' }
  let(:user) { create(:user) }
  let(:org_a) { create(:organisation) }
  let(:org_b) { create(:organisation) }

  after { ActsAsTenant.current_tenant = nil }

  # account_admin membership -> TicketPolicy::Scope returns all, area_access short-circuits.
  def admin_member(target_user, org, active: true)
    role = create(:role, title: 'account_admin', organisation: org)
    create(:membership, user: target_user, organisation: org, role: role, active: active)
  end

  def member_without_access(target_user, org)
    role = create(:role, title: 'Member', organisation: org)
    create(:membership, user: target_user, organisation: org, role: role, active: true)
  end

  # Status attribute with system functions so closed/backlog are recognised.
  def status_definition(project)
    create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', system: true,
                                         options: { 'allowed_values' => [
                                           { 'value' => 'open', 'labels' => { 'de' => 'Offen' }, 'system_functions' => ['is_new'] },
                                           { 'value' => 'done', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] },
                                           { 'value' => 'backlog', 'labels' => { 'de' => 'Backlog' }, 'system_functions' => ['is_backlog'] }
                                         ] })
  end

  def assigned_ticket(org, project, status: 'open')
    ticket = create(:ticket, project: project, organisation: org, custom_attributes: { 'status' => status })
    create(:ticket_assignment, ticket: ticket, user: user)
    ticket
  end

  describe '#slices / #total' do
    it 'aggregates the user\'s assigned open tickets for orgs they belong to' do
      ActsAsTenant.with_tenant(org_a) do
        admin_member(user, org_a)
        project = create(:project, organisation: org_a)
        status_definition(project)
        2.times { assigned_ticket(org_a, project) }
      end

      expect(summary.slices.map(&:organisation)).to contain_exactly(org_a)
      expect(summary.slices.first.ticket_count).to eq(2)
      expect(summary.total).to eq(2)
    end

    it 'never includes data from an org the user is not a member of (tenant isolation)' do
      stranger_org = create(:organisation)
      ActsAsTenant.with_tenant(stranger_org) do
        project = create(:project, organisation: stranger_org)
        status_definition(project)
        assigned_ticket(stranger_org, project) # assigned, but the user is not a member
      end

      expect(summary.slices).to be_empty
      expect(summary.total).to eq(0)
    end

    it 'applies permissions per org: admin in one org, no-access member in another' do
      ActsAsTenant.with_tenant(org_a) do
        admin_member(user, org_a)
        project = create(:project, organisation: org_a)
        status_definition(project)
        assigned_ticket(org_a, project)
      end
      ActsAsTenant.with_tenant(org_b) do
        member_without_access(user, org_b)
        project = create(:project, organisation: org_b)
        status_definition(project)
        assigned_ticket(org_b, project) # assigned but the member cannot read this project
      end

      expect(summary.slices.map(&:organisation)).to contain_exactly(org_a)
      expect(summary.total).to eq(1)
    end

    it 'excludes closed and backlog tickets, keeping only active work' do
      ActsAsTenant.with_tenant(org_a) do
        admin_member(user, org_a)
        project = create(:project, organisation: org_a)
        status_definition(project)
        assigned_ticket(org_a, project, status: 'open')
        assigned_ticket(org_a, project, status: 'done')
        assigned_ticket(org_a, project, status: 'backlog')
      end

      expect(summary.total).to eq(1)
    end
  end

  describe 'unread notifications (ALL unread, not just mentions — Plan B)' do
    it 'counts every unread in-app notification and includes them in #total' do
      ActsAsTenant.with_tenant(org_a) do
        admin_member(user, org_a)
        project = create(:project, organisation: org_a)
        create(:notification, recipient: user, organisation: org_a, project: project, channel: 'in_app',
                              state: 'queued', event_type: Notifications::Constants::EVENT_TYPE_MENTION,
                              dedupe_fingerprint: 'fp-mention-unread')
        create(:notification, recipient: user, organisation: org_a, project: project, channel: 'in_app',
                              state: 'queued', event_type: Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED,
                              dedupe_fingerprint: 'fp-assigned-unread')
        create(:notification, recipient: user, organisation: org_a, project: project, channel: 'in_app',
                              state: 'read', event_type: Notifications::Constants::EVENT_TYPE_MENTION,
                              dedupe_fingerprint: 'fp-mention-read')
      end

      slice = summary.slices.find { |s| s.organisation == org_a }
      expect(slice.notification_count).to eq(2)  # both unread (mention + assigned); read one excluded
      expect(slice.unread_count).to eq(2)        # tile count == notification_count by construction
      expect(summary.total).to eq(2)             # 0 tickets + 2 unread notifications
    end
  end

  describe 'importance levels (ticket filtering)' do
    context "when importance is 'notifications'" do
      let(:importance) { 'notifications' }

      it 'shows no tickets at all, only unread notifications' do
        ActsAsTenant.with_tenant(org_a) do
          admin_member(user, org_a)
          project = create(:project, organisation: org_a)
          status_definition(project)
          assigned_ticket(org_a, project, status: 'open') # would show under :all, hidden here
          create(:notification, recipient: user, organisation: org_a, project: project, channel: 'in_app',
                                state: 'queued', event_type: Notifications::Constants::EVENT_TYPE_MENTION,
                                dedupe_fingerprint: 'fp-only-notif')
        end

        slice = summary.slices.find { |s| s.organisation == org_a }
        expect(slice.ticket_count).to eq(0)
        expect(slice.notification_count).to eq(1)
      end
    end

    context "when importance is 'important'" do
      let(:importance) { 'important' }

      it 'shows only overdue OR high-priority assigned tickets, not plain ones' do
        overdue = high = plain = nil
        ActsAsTenant.with_tenant(org_a) do
          admin_member(user, org_a)
          project = create(:project, organisation: org_a)
          status_definition(project)
          overdue = create(:ticket, project: project, organisation: org_a,
                                    custom_attributes: { 'status' => 'open', 'due_date' => 2.days.ago.to_date.iso8601 })
          create(:ticket_assignment, ticket: overdue, user: user)
          high = create(:ticket, project: project, organisation: org_a,
                                 custom_attributes: { 'status' => 'open', 'priority' => 'hoch' })
          create(:ticket_assignment, ticket: high, user: user)
          plain = assigned_ticket(org_a, project, status: 'open') # normal, no due date -> hidden
        end

        slice = summary.slices.find { |s| s.organisation == org_a }
        expect(slice.tickets).to include(overdue, high)
        expect(slice.tickets).not_to include(plain)
        expect(slice.ticket_count).to eq(2)
      end
    end

    context "when importance is 'all'" do
      let(:importance) { 'all' }

      it 'shows every assigned active ticket, including plain ones' do
        ActsAsTenant.with_tenant(org_a) do
          admin_member(user, org_a)
          project = create(:project, organisation: org_a)
          status_definition(project)
          3.times { assigned_ticket(org_a, project, status: 'open') }
        end

        slice = summary.slices.find { |s| s.organisation == org_a }
        expect(slice.ticket_count).to eq(3)
      end
    end

    it 'defaults to the canonical default importance when given an unknown level' do
      bogus = described_class.new(user: user, importance: 'garbage')
      # 'important' is the default: a plain open ticket is filtered out (not overdue/high).
      ActsAsTenant.with_tenant(org_a) do
        admin_member(user, org_a)
        project = create(:project, organisation: org_a)
        status_definition(project)
        assigned_ticket(org_a, project, status: 'open')
      end

      slice = bogus.slices.find { |s| s.organisation == org_a }
      expect(slice).to be_nil # nothing actionable under the defaulted 'important' level
    end
  end

  describe 'empty + partial-empty' do
    it 'lists only orgs with items but exposes unread_counts for every active org' do
      ActsAsTenant.with_tenant(org_a) do
        admin_member(user, org_a)
        project = create(:project, organisation: org_a)
        status_definition(project)
        assigned_ticket(org_a, project)
      end
      ActsAsTenant.with_tenant(org_b) { admin_member(user, org_b) } # member, nothing open

      expect(summary.slices.map(&:organisation)).to contain_exactly(org_a)
      expect(summary.unread_counts.keys).to contain_exactly(org_a.id, org_b.id)
    end

    it 'returns no slices and zero total when everything is clean' do
      ActsAsTenant.with_tenant(org_a) { admin_member(user, org_a) }

      expect(summary.slices).to be_empty
      expect(summary.total).to eq(0)
    end
  end

  describe 'active membership only' do
    it 'ignores organisations where the membership is inactive' do
      ActsAsTenant.with_tenant(org_a) do
        admin_member(user, org_a, active: false)
        project = create(:project, organisation: org_a)
        status_definition(project)
        assigned_ticket(org_a, project)
      end

      expect(summary.slices).to be_empty
      expect(summary.unread_counts).to be_empty
    end
  end

  describe 'per-org error resilience' do
    it 'skips an org whose aggregation raises, keeping the others and not failing the page' do
      ActsAsTenant.with_tenant(org_a) do
        admin_member(user, org_a)
        project = create(:project, organisation: org_a)
        status_definition(project)
        assigned_ticket(org_a, project)
      end
      ActsAsTenant.with_tenant(org_b) { admin_member(user, org_b) }

      # Blow up only org_b's aggregation (project-access resolution is the first per-org read).
      allow(summary).to receive(:accessible_project_ids).and_wrap_original do |original, org|
        org == org_b ? raise(StandardError, 'boom') : original.call(org)
      end

      expect { summary.slices }.not_to raise_error
      error_slice = summary.slices.find { |s| s.organisation == org_b }
      expect(error_slice.error).to be(true)
      expect(summary.slices.find { |s| s.organisation == org_a }.ticket_count).to eq(1)
    end
  end
end
