# frozen_string_literal: true

require 'rails_helper'

# What: Overview::MyMentionsComponent — the viewer's recent unread @-mentions.
# Type: Component spec (route-free empty state + limit logic; populated list -> request spec).
# Why:  Pins the configurable limit and that no mentions show the in-card empty state (always renders,
#       no permission gate — mentions are recipient-scoped).
RSpec.describe Overview::MyMentionsComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def component(limit: nil)
    described_class.new(organisation: organisation, user: user,
                        briefing: instance_double(Dashboard::DailyBriefing), limit: limit)
  end

  it 'shows the empty state when there are no unread mentions' do
    render_inline(component)
    expect(page).to have_text(I18n.t('overview.mentions.empty'))
  end

  it 'honours a whitelisted item limit' do
    expect(component(limit: '20').send(:effective_limit)).to eq(20)
  end

  # The widget lists through Notification.recent, by the latest event of a row: a mention whose later
  # event folded into it keeps its created_at, still comes first and prints the time of that event.
  # Renders links in real time: no freeze_time, times relative to Time.current.
  describe 'order and printed time' do
    let(:project) { create(:project, organisation: organisation) }
    let(:ticket) { create(:ticket, project: project, organisation: organisation) }

    before do
      role = create(:role, title: 'account_admin', organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end

    def mention(actor:, created_at:, last_event_at:)
      create(:notification, recipient: user, organisation: organisation, project: project, notifiable: ticket,
                            actor: actor, channel: 'in_app', state: 'queued',
                            event_type: Notifications::Constants::EVENT_TYPE_MENTION,
                            created_at: created_at, first_event_at: created_at, last_event_at: last_event_at)
    end

    it 'lists a mention by its latest event first and prints the time of that event' do
      mention(actor: create(:user, first_name: 'Ben', last_name: 'Sued'),
              created_at: 1.hour.ago, last_event_at: 1.hour.ago)
      # Written last: without an order the table hands rows back as written, so the
      # row with the latest event must not come first by accident.
      mention(actor: create(:user, first_name: 'Anna', last_name: 'Nord'),
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
