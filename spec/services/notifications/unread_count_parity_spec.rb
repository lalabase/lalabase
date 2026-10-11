# frozen_string_literal: true

require 'rails_helper'

# "How many unread messages does this person have in organisation X?" is asked in seven
# places: the cockpit tile, the nav badge, the org switcher, the inbox list, the token
# inbox (API + MCP), the mobile nav and the bell dropdown. Until 2026-10-02 they answered
# with four different rules: the cockpit left out archived projects, the badge and the
# token inbox counted them for an account admin, and the mobile nav and the dropdown
# asked no access question at all. A reader moving from the cockpit to the inbox saw two
# numbers for one inbox.
#
# The rule now has ONE owner, Notification.inbox_unread / Notification.accessible_for:
# unread in-app rows of the organisation whose project is an ACTIVE project the person
# may read, plus rows without a project (system messages). This spec asks every surface
# the same question about the same rows and expects the same answer.
RSpec.describe 'Unread count parity across surfaces', :ci_guard do
  let(:user) { create(:user) }
  let(:org_admin) { create(:organisation) }
  let(:org_member) { create(:organisation) }

  # org_admin: the person is account admin. One active project, one archived project.
  let(:live_project) { ActsAsTenant.with_tenant(org_admin) { create(:project, organisation: org_admin) } }
  let(:archived_project) do
    ActsAsTenant.with_tenant(org_admin) { create(:project, organisation: org_admin, archived_at: 1.day.ago) }
  end
  # org_member: an ordinary member with read access to one project, none to the other.
  let(:readable_project) { ActsAsTenant.with_tenant(org_member) { create(:project, organisation: org_member) } }
  let(:hidden_project) { ActsAsTenant.with_tenant(org_member) { create(:project, organisation: org_member) } }

  # The cockpit renders without a tenant; leave none behind for the next example.
  after { ActsAsTenant.current_tenant = nil }

  before do
    ActsAsTenant.with_tenant(org_admin) do
      role = create(:role, title: 'account_admin', organisation: org_admin)
      create(:membership, user: user, organisation: org_admin, role: role, active: true)
    end
    ActsAsTenant.with_tenant(org_member) do
      role = create(:role, title: 'Member', organisation: org_member)
      create(:membership, user: user, organisation: org_member, role: role, active: true)
      create(:project_permission, user: user, project: readable_project, tickets_access: 'read_write')
    end

    unread(org_admin, project: live_project)      # counts
    unread(org_admin, project: archived_project)  # does NOT count: archived project
    unread(org_admin, project: nil)               # counts: system message
    unread(org_admin, project: live_project, state: 'read') # does NOT count: read

    unread(org_member, project: readable_project) # counts
    unread(org_member, project: hidden_project)   # does NOT count: no access
    unread(org_member, project: nil)              # counts: system message
  end

  let(:expected) { { org_admin.id => 2, org_member.id => 2 } }

  def unread(org, project:, state: 'queued')
    ActsAsTenant.with_tenant(org) do
      create(:notification, recipient: user, organisation: org, project: project, channel: 'in_app', state: state)
    end
  end

  # The loop over two organisations repeats its queries by design; paused so
  # Prosopite reads it as what it is, not as an N+1 in the code under test.
  def per_organisation
    Prosopite.pause do
      [org_admin, org_member].to_h { |org| [org.id, ActsAsTenant.with_tenant(org) { yield(org) }] }
    end
  end

  it 'cockpit tile (Dashboard::CrossOrgActionSummary#unread_counts)' do
    counts = Dashboard::CrossOrgActionSummary.new(user: user, importance: 'all').unread_counts
    expect(counts.slice(*expected.keys)).to eq(expected)
  end

  it 'nav badge and live badge broadcast (User#unread_notifications_count)' do
    expect(per_organisation { |org| user.unread_notifications_count(org) }).to eq(expected)
  end

  it 'org switcher (Notifications::UnreadSignals.counts_for)' do
    expect(Notifications::UnreadSignals.counts_for(user, except: [])).to eq(expected)
  end

  it 'inbox list (NotificationPolicy::Scope, unread in-app rows)' do
    counts = per_organisation do
      NotificationPolicy::Scope.new(user, Notification).resolve.channel_in_app.unread.count
    end
    expect(counts).to eq(expected)
  end

  it 'token inbox, API and MCP (Notifications::InboxQuery)' do
    counts = Prosopite.pause do
      [org_admin, org_member].to_h do |org|
        token = create(:personal_access_token, user: user, organisations: [org])
        [org.id, Notifications::InboxQuery.call(user: user, reach: token.reach).total]
      end
    end
    expect(counts).to eq(expected)
  end

  it 'token inbox per organisation (Notifications::InboxQuery#by_organisation)' do
    token = create(:personal_access_token, user: user, organisations: [org_admin, org_member])
    counts = Notifications::InboxQuery.call(user: user, reach: token.reach).by_organisation
    expect(counts.to_h { |o| [o[:id], o[:unread]] }).to eq(expected)
  end

  # The two components below compute their number in a private method. Asked directly
  # rather than through rendered markup: the badge markup caps or hides numbers, and this
  # spec is about the number, not its look.
  it 'mobile nav (NeoMobileNavComponent)' do
    counts = per_organisation do |org|
      NeoMobileNavComponent.new(user: user, organisation: org).send(:unread_count)
    end
    expect(counts).to eq(expected)
  end

  it 'bell dropdown (NeoNotificationDropdownComponent)' do
    counts = per_organisation do |org|
      NeoNotificationDropdownComponent.new(user: user, organisation: org).send(:unread_count)
    end
    expect(counts).to eq(expected)
  end

  it 'bell dropdown lists the rows the inbox lists' do
    rows = per_organisation do |org|
      NeoNotificationDropdownComponent.new(user: user, organisation: org).send(:recent_notifications).map(&:id).sort
    end
    inbox = per_organisation do
      NotificationPolicy::Scope.new(user, Notification).resolve.channel_in_app.inbox.pluck(:id).sort
    end
    expect(rows).to eq(inbox)
  end

  # The layout asks three surfaces for this number on every page; the project access behind it
  # is resolved once per request (Current.notification_source_projects), once per area the
  # rule asks (Notification::AREA_BY_NOTIFIABLE_TYPE, the areas of the events on a project,
  # plus "any area" for the rest and for project news).
  it 'resolves project access once per area for the surfaces of one page' do
    event_areas = Activities::AreaRegistry.project_actions_by_area.keys - [Activities::AreaRegistry::PROJECT_LEVEL]
    [nil, *Notification::AREA_BY_NOTIFIABLE_TYPE.values, *event_areas].uniq.each do |area|
      expect(AccessCheck::ProjectAccessService).to receive(:accessible_projects)
        .with(user, org_member, area: area).once.and_call_original
    end

    ActsAsTenant.with_tenant(org_member) do
      user.unread_notifications_count(org_member)
      user.unread_notifications_count(org_member)
      NeoMobileNavComponent.new(user: user, organisation: org_member).send(:unread_count)
    end
  end

  it 'bell dropdown offers "view all" by the rows the inbox shows, not by hidden ones' do
    Prosopite.pause do
      ActsAsTenant.with_tenant(org_member) do
        create_list(:notification, 3, recipient: user, organisation: org_member, project: hidden_project,
                                      channel: 'in_app', state: 'queued')
      end
    end
    offered = ActsAsTenant.with_tenant(org_member) do
      NeoNotificationDropdownComponent.new(user: user, organisation: org_member, limit: 2).send(:show_view_all_button?)
    end
    # Visible: the readable row and the system row, 2 = limit. Hidden: 4 rows that must not count.
    expect(offered).to be(false)
  end

  it 'counts past the length of the dropdown list' do
    # Setup only: the factory's callbacks repeat a lookup per record.
    Prosopite.pause do
      ActsAsTenant.with_tenant(org_admin) do
        create_list(:notification, 11, recipient: user, organisation: org_admin, project: live_project,
                                       channel: 'in_app', state: 'queued')
      end
    end
    count = ActsAsTenant.with_tenant(org_admin) do
      NeoNotificationDropdownComponent.new(user: user, organisation: org_admin, limit: 10).send(:unread_count)
    end
    expect(count).to eq(13)
  end
end
