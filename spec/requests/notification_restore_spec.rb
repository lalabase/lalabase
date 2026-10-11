# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Notification restore', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  let!(:notification) do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: user,
             organisation: organisation,
             state: :archived,
             archived_at: 1.day.ago)
    end
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
  end

  it 'restores archived notification via mark_unread path' do
    patch mark_unread_organisation_notification_path(organisation, notification),
          params: { view_variant: 'grouped' },
          headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

    expect(response).to have_http_status(:see_other).or have_http_status(:ok)
    expect(notification.reload).to be_state_queued
    expect(notification.archived_at).to be_nil
  end
end
