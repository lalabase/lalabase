# frozen_string_literal: true

require 'rails_helper'

# What: Overview::PortfolioStats — org-wide aggregates for the portfolio widgets (org_stats_cards +
#       billing_overview).
# Type: Service spec (DB-backed).
# Why:  Pins (1) the billing pipeline split — unbilled-loose vs unbilled-grouped vs billed, all in
#       hours (the data model has no monetary rate); (2) that every aggregate is PERMISSION-SCOPED to
#       the viewer's accessible projects (no leak of projects/tickets/hours they cannot see); and
#       (3) the empty-portfolio zero state.
RSpec.describe Overview::PortfolioStats do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  subject(:stats) { described_class.new(organisation: organisation, user: user) }

  context 'as an account admin (sees every project)' do
    let!(:admin_membership) do
      create(:membership, user: user, organisation: organisation,
                          role: create(:role, organisation: organisation, title: 'account_admin'))
    end
    let!(:project_a) { create(:project, organisation: organisation) }
    let!(:project_b) { create(:project, organisation: organisation) }
    let!(:archived)  { create(:project, organisation: organisation, archived_at: Time.current) }

    it 'counts only ACTIVE projects' do
      expect(stats.active_projects_count).to eq(2)
    end

    it 'counts open tickets across all projects (no closed-status defs -> all open)' do
      create(:ticket, project: project_a)
      create(:ticket, project: project_a)
      create(:ticket, project: project_b)

      expect(stats.open_tickets_count).to eq(3)
    end

    it 'counts overdue tickets (past due AND not closed), excluding closed/future/no-date' do
      allowed = [
        { 'value' => 'Offen',    'labels' => { 'de' => 'Offen' },    'system_functions' => ['is_new'] },
        { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] }
      ]
      create(:ticket_attribute_definition, project: project_a, name: 'status', field_type: 'select',
                                           system: true, options: { 'allowed_values' => allowed })
      create(:ticket_attribute_definition, project: project_a, name: 'due_date', field_type: 'date',
                                           labels: { 'de' => 'Fälligkeit', 'en' => 'Due date' })

      create(:ticket, project: project_a, custom_attributes: { 'due_date' => 2.days.ago.to_date.iso8601, 'status' => 'Offen' })     # overdue + open -> counted
      create(:ticket, project: project_a, custom_attributes: { 'due_date' => 2.days.ago.to_date.iso8601, 'status' => 'Erledigt' })  # overdue but closed -> excluded
      create(:ticket, project: project_a, custom_attributes: { 'due_date' => 3.days.from_now.to_date.iso8601, 'status' => 'Offen' }) # future -> excluded
      create(:ticket, project: project_a, custom_attributes: { 'status' => 'Offen' })                                                # no due date -> excluded

      expect(stats.overdue_tickets_count).to eq(1)
    end

    # Regression (#126): "open" is ACTIVE WORK — excludes closed (is_completed/is_closed) AND backlog
    # (is_backlog) statuses, via excluding_status_values (the renamed/generalised excluding_closed).
    # A nil/untriaged status stays open. Guards the parallel-merge break that 500'd the live overview.
    it 'counts only active-work tickets (excludes closed and backlog, keeps untriaged)' do
      allowed = [
        { 'value' => 'Offen',    'labels' => { 'de' => 'Offen' },    'system_functions' => ['is_new'] },
        { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] },
        { 'value' => 'Backlog',  'labels' => { 'de' => 'Backlog' },  'system_functions' => ['is_backlog'] }
      ]
      create(:ticket_attribute_definition, project: project_a, name: 'status', field_type: 'select',
                                           system: true, options: { 'allowed_values' => allowed })

      create(:ticket, project: project_a, custom_attributes: { 'status' => 'Offen' })
      create(:ticket, project: project_a, custom_attributes: { 'status' => 'Erledigt' }) # closed -> excluded
      create(:ticket, project: project_a, custom_attributes: { 'status' => 'Backlog' })  # backlog -> excluded
      create(:ticket, project: project_a) # nil status -> kept (untriaged is not parked)

      expect(stats.open_tickets_count).to eq(2)
    end

    describe 'billing pipeline (hours)' do
      let!(:group) { create(:time_session_group, organisation: organisation) }

      before do
        # 90 min loose unbilled, 120 min grouped unbilled, 60 min billed.
        create(:time_session, project: project_a, creator: user, duration: 90, billed: false)
        create(:time_session, project: project_a, creator: user, duration: 120, billed: false, time_session_group: group)
        create(:time_session, project: project_b, creator: user, duration: 60, billed: true)
      end

      it 'splits unbilled-loose / unbilled-grouped / billed' do
        expect(stats.without_billing_hours).to eq(1.5)
        expect(stats.in_billing_hours).to eq(2.0)
        expect(stats.billed_hours).to eq(1.0)
      end

      it 'reports total unbilled hours as loose + grouped (not the billed ones)' do
        expect(stats.unbilled_hours).to eq(3.5)
      end
    end
  end

  context 'as a member with access to only one project' do
    let!(:member_membership) do
      create(:membership, user: user, organisation: organisation,
                          role: create(:role, organisation: organisation, title: 'member'))
    end
    let!(:visible) { create(:project, organisation: organisation) }
    let!(:hidden)  { create(:project, organisation: organisation) }
    let!(:permission) { create(:project_permission, user: user, project: visible, tickets_access: 'read_only') }

    it 'counts only the projects the viewer can access' do
      expect(stats.active_projects_count).to eq(1)
    end

    it 'never counts tickets from a project the viewer cannot see' do
      create(:ticket, project: visible)
      create(:ticket, project: hidden)
      create(:ticket, project: hidden)

      expect(stats.open_tickets_count).to eq(1)
    end
  end

  context 'with no accessible projects' do
    let!(:member_membership) do
      create(:membership, user: user, organisation: organisation,
                          role: create(:role, organisation: organisation, title: 'member'))
    end

    it 'reports zeros everywhere (no division by zero, no stray queries)' do
      expect(stats.active_projects_count).to eq(0)
      expect(stats.open_tickets_count).to eq(0)
      expect(stats.unbilled_hours).to eq(0.0)
      expect(stats.billed_hours).to eq(0.0)
    end
  end
end
