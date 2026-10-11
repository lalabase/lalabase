# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Notification deep link', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  let!(:project) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project, organisation: organisation)
    end
  end

  # The recipient of a project notification is someone who can reach that project. The
  # fixtures used to leave this out, which is a shape no real account has, and the deep
  # link then measured itself against a user the inbox would not show the row to at all.
  let!(:permission) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission, user: user, project: project, tickets_access: 'read_write')
    end
  end

  let!(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project)
    end
  end

  let!(:notification) do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: user,
             organisation: organisation,
             project: project,
             notifiable: ticket,
             state: :delivered)
    end
  end

  let!(:second_notification) do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: user,
             organisation: organisation,
             project: project,
             notifiable: ticket,
             state: :sent)
    end
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
  end

  it 'marks related notifications as read and redirects to the ticket' do
    broadcast_double = instance_double(Notifications::BroadcastService, broadcast_update: true)
    allow(Notifications::BroadcastService).to receive(:new).and_return(broadcast_double)

    get open_organisation_notification_path(organisation, notification)

    expect(response).to redirect_to(
      organisation_project_ticket_path(organisation, project, ticket, from_notification: true)
    )
    expect(notification.reload).to be_state_read
    expect(second_notification.reload).to be_state_read
    expect(Notifications::BroadcastService).to have_received(:new).twice
  end

  # A deep link outlives the access it was sent with: the mail sits in a mailbox long
  # after someone is taken off the project. Finding a notification by id must not be the
  # way around the gate that the inbox listing applies.
  context 'once the recipient has lost the project' do
    before { permission.update!(tickets_access: 'no_access') }

    it 'refuses the link instead of opening the ticket' do
      get open_organisation_notification_path(organisation, notification)

      expect(response).not_to have_http_status(:see_other)
    end

    it 'does not mark anything as read' do
      get open_organisation_notification_path(organisation, notification)

      expect(notification.reload).not_to be_state_read
    end
  end
end
