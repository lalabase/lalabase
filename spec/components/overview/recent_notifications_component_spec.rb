# frozen_string_literal: true

require 'rails_helper'

# What: Overview::RecentNotificationsComponent — the latest-notifications list widget.
# Type: Component spec (always-renders + route-free empty state + limit logic; populated list with
#       links -> covered by the briefings request spec).
# Why:  Pins that it always renders (recipient-scoped) with an in-card empty state, and the
#       configurable limit (shared sanitise-or-default).
RSpec.describe Overview::RecentNotificationsComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def component(limit: nil)
    described_class.new(organisation: organisation, user: user,
                        briefing: instance_double(Dashboard::DailyBriefing), limit: limit)
  end

  it 'always renders (recipient-scoped)' do
    expect(component.should_render?).to be true
  end

  it 'shows the empty state when there are no notifications' do
    render_inline(component)
    expect(page).to have_text(I18n.t('overview.notifications.empty'))
  end

  it 'honours a whitelisted item limit' do
    expect(component(limit: '15').send(:effective_limit)).to eq(15)
  end

  # The "who · where" sub-line is the actionability fix: a bare "Kommentar hinzugefügt" becomes
  # "<actor> · <project>". Each part drops out when absent (system events have no actor; some events
  # carry no project), so the dot never dangles.
  describe '#context_label' do
    it 'joins actor and project with a dot separator' do
      # Render first: since S3 the actor name resolves through
      # helpers.viewer_display_name, and #helpers only exists once the
      # component entered the render pipeline.
      rendered_component = component
      render_inline(rendered_component)
      notification = instance_double(Notification, actor: instance_double(User, display_name: 'Maria M.'),
                                                   project: instance_double(Project, name: 'Projekt Alpha'))
      expect(rendered_component.send(:context_label, notification)).to eq('Maria M. · Projekt Alpha')
    end

    it 'drops the actor for a system event (no actor), keeping just the project' do
      notification = instance_double(Notification, actor: nil,
                                                   project: instance_double(Project, name: 'Projekt Alpha'))
      expect(component.send(:context_label, notification)).to eq('Projekt Alpha')
    end

    it 'is blank when neither actor nor project is present (no dangling separator)' do
      notification = instance_double(Notification, actor: nil, project: nil)
      expect(component.send(:context_label, notification)).to eq('')
    end
  end

  # The widget lists through Notification.recent, by the latest event of a row: a row whose later
  # event folded into it keeps its created_at, still comes first and prints the time of that event.
  # Renders avatars and links in real time: no freeze_time, times relative to Time.current.
  describe 'order and printed time' do
    let(:project) { create(:project, organisation: organisation) }
    let(:ticket) { create(:ticket, project: project, organisation: organisation) }

    before do
      role = create(:role, title: 'account_admin', organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end

    def row(actor:, created_at:, last_event_at:)
      create(:notification, recipient: user, organisation: organisation, project: project, notifiable: ticket,
                            actor: actor, channel: 'in_app', state: 'queued', event_type: 'ticket_commented',
                            created_at: created_at, first_event_at: created_at, last_event_at: last_event_at)
    end

    it 'lists a row by its latest event first and prints the time of that event' do
      row(actor: create(:user, first_name: 'Ben', last_name: 'Sued'),
          created_at: 1.hour.ago, last_event_at: 1.hour.ago)
      # Written last: without an order the table hands rows back as written, so the
      # row with the latest event must not come first by accident.
      row(actor: create(:user, first_name: 'Anna', last_name: 'Nord'),
          created_at: 3.days.ago, last_event_at: 5.minutes.ago)

      # Paused for the render only: each row's link reads its organisation once
      # (NotificationsHelper#notification_target_path), an N+1 this widget had
      # before and that is not about the order.
      Prosopite.pause { render_inline(component) }

      rows = page.all('li')
      expect(rows.map { |node| node.text[/Anna Nord|Ben Sued/] }).to eq(['Anna Nord', 'Ben Sued'])
      expect(rows.first.text).to include('5 Minuten')
    end
  end
end
