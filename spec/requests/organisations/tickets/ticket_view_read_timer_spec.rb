# frozen_string_literal: true

require 'rails_helper'

# What: the ticket view carries the 5-second read timer (pane_mark_read_delay) that
#       calls .../notification_read, but only while the viewer has something unread
#       about the ticket, and not inside the inbox pane, which times its own
#       notification.
RSpec.describe 'Ticket view read timer', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }
  let(:timer_url) { organisation_project_ticket_notification_read_path(organisation, project, ticket) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def unread_notification
    create(:notification, recipient: user, organisation: organisation, project: project, channel: 'in_app',
                          state: 'queued', event_type: Notifications::Constants::EVENT_TYPE_MENTION,
                          notifiable: ticket, dedupe_fingerprint: SecureRandom.hex(8))
  end

  def timers
    Nokogiri::HTML(response.body).css('[data-controller="pane-mark-read-delay"]')
            .map { |node| node['data-pane-mark-read-delay-url-value'] }
  end

  it 'starts the timer on the ticket page while something is unread' do
    unread_notification

    get organisation_project_ticket_path(organisation, project, ticket)

    expect(response).to have_http_status(:ok)
    expect(timers).to eq([timer_url])
  end

  it 'starts no timer when nothing is unread' do
    get organisation_project_ticket_path(organisation, project, ticket)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(ticket.title)
    expect(timers).to be_empty
  end

  it 'leaves the inbox pane with its own timer only' do
    notification = unread_notification

    get organisation_notifications_path(organisation, notification: notification.id)

    expect(response).to have_http_status(:ok)
    expect(timers).to eq([mark_read_organisation_notification_path(organisation, notification)])
  end
end
