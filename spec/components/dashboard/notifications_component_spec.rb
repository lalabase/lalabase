# frozen_string_literal: true

require 'rails_helper'

# The notifications card of the project dashboard orders its unread rows through
# Notification.recent, by the latest event of a row, and prints that event's time:
# a row whose later event folded into it keeps its created_at, so ordering or
# printing by created_at would put it behind newer rows and call it days old.
# Renders the card in real time: no freeze_time, times relative to Time.current.
RSpec.describe Dashboard::NotificationsComponent, type: :component do
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

  def row(title:, created_at:, last_event_at:)
    create(:notification, recipient: user, organisation: organisation, project: project, notifiable: ticket,
                          channel: 'in_app', state: 'queued', payload: { 'title' => title },
                          created_at: created_at, first_event_at: created_at, last_event_at: last_event_at)
  end

  it 'lists a row by its latest event first and prints the time of that event' do
    row(title: 'Fresh row', created_at: 1.hour.ago, last_event_at: 1.hour.ago)
    # Written last: without an order the table hands rows back as written, so the
    # row with the latest event must not come first by accident.
    row(title: 'Folded row', created_at: 3.days.ago, last_event_at: 5.minutes.ago)

    render_inline(described_class.new(project: project, user: user, limit: 5))

    rows = page.all('.space-y-3 > div')
    expect(rows.map { |node| node.find('p.font-medium').text.strip }).to eq(['Folded row', 'Fresh row'])
    expect(rows.first.text).to include('5 Minuten')
  end
end
