# frozen_string_literal: true

require 'rails_helper'

# The bell dropdown lists the inbox rows through Notification.recent, by the latest
# event of a row: a row whose later event folded into it keeps its created_at and
# still comes first, and the time it prints is that latest event.
# Renders avatars, so real time: no freeze_time, times relative to Time.current.
RSpec.describe NeoNotificationDropdownComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    role = create(:role, title: 'account_admin', organisation: organisation)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
  end

  after { ActsAsTenant.current_tenant = nil }

  def row(created_at:, last_event_at:)
    create(:notification, recipient: user, organisation: organisation, project: project, notifiable: ticket,
                          channel: 'in_app', state: 'queued', event_type: 'ticket_commented',
                          created_at: created_at, first_event_at: created_at, last_event_at: last_event_at)
  end

  it 'lists a row by its latest event first and prints the time of that event' do
    folded = row(created_at: 3.days.ago, last_event_at: 5.minutes.ago)
    fresh = row(created_at: 1.hour.ago, last_event_at: 1.hour.ago)

    render_inline(described_class.new(user: user, organisation: organisation, limit: 10))

    ids = page.all('[data-notification-id]', visible: :all).map { |node| node['data-notification-id'] }
    expect(ids).to eq([folded.id, fresh.id])
    folded_time = page.find("[data-notification-id='#{folded.id}'] .notification-time", visible: :all)
    expect(folded_time.text(:all)).to include('5 Minuten')
  end
end
