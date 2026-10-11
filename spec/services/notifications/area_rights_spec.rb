# frozen_string_literal: true

require 'rails_helper'

# A notification about something in an area (a ticket, a note, a document) is
# listed, counted and opened only while its recipient may read that area. Every
# surface asks the same rule: the inbox list and its policy, every counter (the
# badge, the cockpit tile, the org switcher), and the token inbox (REST and MCP).
#
# Until 2026-10-07 the read side asked only "may see the project at all": a
# person left with notes alone still saw the id, number and CURRENT title of
# tickets they could no longer open (review of gboyke/lalabase#970).
#
# Derived, never stored: getting the right back brings the rows back.
# Plan: lalabase-private doc/benachrichtigungen_bereichsrechte_plan.md.
RSpec.describe 'Notifications by area rights', :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation) }
  let(:user) { create(:user) }
  let(:author) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  # Notes only: the project is reachable, its tickets and documents are not.
  let!(:permission) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      create(:project_permission, user: user, project: project, notes_access: 'read_only')
    end
  end

  def row(notifiable, project: self.project)
    ActsAsTenant.with_tenant(organisation) do
      create(:notification, recipient: user, organisation: organisation, project: project,
                            notifiable: notifiable, channel: 'in_app', state: 'queued')
    end
  end

  let!(:rows) do
    ActsAsTenant.with_tenant(organisation) do
      ticket = create(:ticket, project: project, organisation: organisation, creator: author, title: 'Geheimplan')
      note = create(:note, project: project, organisation: organisation, creator: author, create_embeddings: false)
      document = create(:document, project: project, organisation: organisation, creator: author)
      {
        ticket: row(ticket), note: row(note), document: row(document),
        project: row(project), system: row(organisation, project: nil)
      }
    end
  end

  let(:readable) { rows.values_at(:note, :project, :system).map(&:id) }

  def accessible_ids
    ActsAsTenant.with_tenant(organisation) do
      Notification.where(recipient: user).accessible_for(user, organisation).pluck(:id)
    end
  end

  it 'lists only what the areas allow' do
    expect(accessible_ids).to match_array(readable)
  end

  it 'counts the same rows everywhere' do
    ActsAsTenant.with_tenant(organisation) do
      expect(Notification.inbox_unread(user, organisation).count).to eq(3)
      expect(user.unread_notifications_count(organisation)).to eq(3)
    end
    expect(Notifications::UnreadSignals.counts_for(user, except: nil)).to eq(organisation.id => 3)

    slice = Dashboard::CrossOrgActionSummary.new(user: user, importance: 'notifications')
                                            .slices.find { |s| s.organisation == organisation }
    expect(slice.unread_count).to eq(3)
    expect(slice.notifications.map(&:id)).to match_array(readable)
  end

  it 'lets the inbox policy open only those rows' do
    ActsAsTenant.with_tenant(organisation) do
      expect(Pundit.policy_scope!(user, Notification).pluck(:id)).to match_array(readable)
      expect(Pundit.policy!(user, rows[:ticket]).show?).to be false
      expect(Pundit.policy!(user, rows[:note]).show?).to be true
    end
  end

  it 'answers the token inbox the same way, list and counts' do
    token = create(:personal_access_token, user: user, organisations: [organisation])
    page = Notifications::InboxQuery.call(user: user, reach: token.reach, status: 'all')
    expect(page.rows.map(&:id)).to match_array(readable)
    expect(page.unread_total).to eq(3)
    expect(page.by_organisation).to eq([{ id: organisation.id, name: organisation.name, unread: 3 }])
  end

  # Every per-project number the overview shows counts by the same rule as the
  # inbox its link leads to (review of #975).
  describe 'per-project numbers' do
    def in_tenant(&) = ActsAsTenant.with_tenant(organisation, &)

    # A read row in the same project: the numbers are about UNREAD rows.
    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation, project: project, notifiable: project,
                              channel: 'in_app', state: 'read', read_at: Time.current)
      end
    end

    it 'project dashboard: the notification list and its count' do
      component = Dashboard::NotificationsComponent.new(project: project, user: user, limit: 10)
      in_tenant do
        expect(component.send(:notifications).map(&:id)).to match_array(rows.values_at(:note, :project).map(&:id))
        expect(component.send(:unread_count)).to eq(2)
      end
    end

    it 'stats card' do
      card = in_tenant { Dashboard::StatsCardsComponent.new(project: project, user: user).send(:compute_notifications) }
      expect(card[:value]).to eq(2)
    end

    it 'daily briefing, projects overview' do
      overview = in_tenant { Dashboard::DailyBriefing.new(user: user, organisation: organisation).projects_overview }
      expect(overview.find { |row| row[:project] == project }[:unread_count]).to eq(2)
    end

    it 'sidebar: a project whose only unread row is hidden is not marked unread' do
      in_tenant do
        Notification.where(id: rows.values_at(:note, :project).map(&:id)).update_all(state: 'read', read_at: Time.current)
        service = SidebarProjectGroupingService.new(user, organisation, projects: [project])
        expect(service.send(:unread_project_ids, [project])).to be_empty
      end
    end

    # Delivery sends the badge the inbox count, by the rule (no project badge:
    # its target was never in any page and it is gone, review of #976).
    it 'badge count sent by delivery' do
      expect(Notifications::BroadcastService).to receive(:new)
        .with(rows[:note], precomputed_unread_count: 3)
        .and_return(instance_double(Notifications::BroadcastService, broadcast_creation: nil))
      in_tenant { Notifications::FanoutService.allocate.send(:batch_broadcast, [rows[:note]]) }
    end
  end

  # The rule measures a row by its project. A ticket that moves takes its
  # notifications along (Tickets::Mover), or a person who may read tickets in
  # the old project but not in the new one would keep the row, with the
  # ticket's current title (review of #976).
  it 'follows a ticket that moves to a project whose tickets the person may not read' do
    admin = create(:user)
    readable_project = nil
    moved = nil
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: create(:admin_role, organisation: organisation),
                          active: true)
      readable_project = create(:project, organisation: organisation)
      create(:project_permission, user: user, project: readable_project, tickets_access: 'read_only')
      moved = create(:ticket, project: readable_project, organisation: organisation, creator: author)
    end
    moved_row = row(moved, project: readable_project)
    expect(accessible_ids).to include(moved_row.id)

    ActsAsTenant.with_tenant(organisation) do
      Tickets::Mover.call(ticket: moved, target_project: project, current_user: admin)
    end
    Current.reset

    expect(moved_row.reload.project_id).to eq(project.id)
    expect(accessible_ids).not_to include(moved_row.id)
  end

  it 'measures a note against the notes area, not documents' do
    ActsAsTenant.with_tenant(organisation) do
      permission.update!(notes_access: 'no_access', documents_access: 'read_only')
    end
    expect(accessible_ids).to match_array(rows.values_at(:document, :project, :system).map(&:id))
  end

  it 'brings the rows back with the right' do
    ActsAsTenant.with_tenant(organisation) { permission.update!(tickets_access: 'read_only') }
    expect(accessible_ids).to include(rows[:ticket].id)
  end

  it 'keeps everything for a person who may read every area' do
    ActsAsTenant.with_tenant(organisation) do
      permission.update!(tickets_access: 'read_write', documents_access: 'read_write')
    end
    expect(accessible_ids).to match_array(rows.values.map(&:id))
  end
end

# The token inbox resolves the areas once per organisation of the token: a bounded
# loop, not an N+1, and Prosopite must see it that way also for a role whose rights
# hold in all projects (one exclusion read per area and organisation).
RSpec.describe 'Notifications by area rights: the token inbox over organisations', :ci_guard do
  it 'answers without an N+1 for a role with rights in all projects' do
    user = create(:user)
    orgs = token = nil
    Prosopite.pause do
      orgs = Array.new(3) { create(:organisation) }
      orgs.each do |org|
        ActsAsTenant.with_tenant(org) do
          role = create(:role, organisation: org)
          %w[tickets notes documents].each { |area| create(:project_read_permission, role: role, area: area) }
          create(:membership, user: user, organisation: org, role: role, active: true)
          project = create(:project, organisation: org)
          create(:notification, recipient: user, organisation: org, project: project, state: 'queued', channel: 'in_app')
        end
      end
      token = create(:personal_access_token, user: user, organisations: orgs)
    end
    Current.reset

    expect(Notifications::InboxQuery.call(user: user, reach: token.reach, status: 'all').rows.size).to eq(3)
  end
end

RSpec.describe 'Notifications by area rights: the inbox pane', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let!(:hidden) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation),
                          active: true)
      create(:project_permission, user: user, project: project, notes_access: 'read_only')
      ticket = create(:ticket, project: project, organisation: organisation, title: 'Geheimplan')
      create(:notification, recipient: user, organisation: organisation, project: project, notifiable: ticket,
                            channel: 'in_app', state: 'queued')
    end
  end

  before do
    sign_in user
    Prosopite.pause # the render path has known N+1 (inbox_pane_flow_spec)
  end

  after { Prosopite.resume }

  # A mail link to somebody else's notification (forwarded, say) must not lead to,
  # and so confirm, a ticket the person may not read (review of #976).
  it 'does not send a foreign notification link on to a ticket the person may not read' do
    other = create(:user)
    foreign = ActsAsTenant.with_tenant(organisation) do
      create(:notification, recipient: other, organisation: organisation, project: project,
                            notifiable: hidden.notifiable, channel: 'email', state: 'queued')
    end
    get open_organisation_notification_path(organisation, foreign)
    expect(response).to redirect_to(organisation_notifications_path(organisation))
  end

  # ?notification= selects a row for the pane. One the person may not see is no row.
  it 'does not select a notification about a hidden ticket' do
    get organisation_notifications_path(organisation), params: { notification: hidden.id }
    expect(response).to have_http_status(:ok)
    expect(controller.instance_variable_get(:@selected_notification)).to be_nil
    expect(response.body).not_to include('Geheimplan')
  end
end
