# frozen_string_literal: true

require 'rails_helper'

# What: PATCH .../tickets/:ticket_id/notification_read, sent by the ticket view after
#       5 seconds (pane_mark_read_delay_controller).
# Why:  Reading is enough to clear one's own marks, so a member with read-only access
#       may do it; a member without access to the project may not, and a ticket of
#       another organisation is not found. The response updates the requesting page:
#       the sidebar count and the ticket's dot in a list beside the view.
RSpec.describe 'Ticket notification read', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def notify(recipient: user, notifiable: ticket)
    create(:notification, recipient: recipient, organisation: organisation, project: project, channel: 'in_app',
                          state: 'queued', event_type: Notifications::Constants::EVENT_TYPE_MENTION,
                          notifiable: notifiable, dedupe_fingerprint: SecureRandom.hex(8))
  end

  def mark_read(target = ticket, org: organisation, proj: project)
    patch organisation_project_ticket_notification_read_path(org, proj, target),
          headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
  end

  context 'as an admin' do
    before do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
      sign_in user
    end

    it 'marks the notifications read and answers with the count and the ticket dot' do
      notification = notify

      mark_read

      expect(response).to have_http_status(:ok)
      expect(notification.reload.state).to eq('read')
      streams = Nokogiri::HTML(response.body)
      expect(streams.at_css('turbo-stream[target="nav_notifications_count"]')).to be_present
      dot_stream = streams.at_css(%(turbo-stream[targets="[data-ticket-unread-for='#{ticket.id}']"]))
      expect(dot_stream).to be_present
      expect(dot_stream.inner_html).not_to include('data-unread-marker')
    end

    it 'does not find a ticket of another organisation' do
      foreign_org = create(:organisation)
      foreign = ActsAsTenant.with_tenant(foreign_org) do
        create(:ticket, project: create(:project, organisation: foreign_org), organisation: foreign_org)
      end
      notification = notify

      mark_read(foreign)

      expect(response).to have_http_status(:not_found)
      expect(notification.reload.state).to eq('queued')
    end
  end

  context 'as a member with read-only access to the project' do
    before do
      create(:membership, user: user, organisation: organisation)
      create(:project_permission, user: user, project: project, tickets_access: 'read_only')
      sign_in user
    end

    it 'may mark its own notifications read' do
      notification = notify

      mark_read

      expect(response).to have_http_status(:ok)
      expect(notification.reload.state).to eq('read')
    end
  end

  context 'as a member without access to the project' do
    before do
      create(:membership, user: user, organisation: organisation)
      sign_in user
    end

    it 'is refused and changes nothing' do
      notification = notify

      mark_read

      expect(response).not_to have_http_status(:ok)
      expect(notification.reload.state).to eq('queued')
    end
  end
end
