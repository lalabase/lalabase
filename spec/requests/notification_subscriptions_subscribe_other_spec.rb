# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'NotificationSubscriptions subscribe_other', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) do
    ActsAsTenant.current_tenant = organisation
    create(:admin_role, organisation: organisation)
  end
  let(:user) { create(:user) }
  let(:target_user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end
  let(:ticket) do
    ActsAsTenant.current_tenant = organisation
    create(:ticket, project: project, creator: user)
  end

  before do
    ActsAsTenant.current_tenant = organisation
    [user, target_user].each do |u|
      create(:membership, user: u, organisation: organisation, role: admin_role, active: true)
    end
    sign_in user
  end

  describe 'POST subscribe_other' do
    let(:path) do
      subscribe_other_organisation_project_ticket_subscription_path(
        organisation, project, ticket
      )
    end

    it 'creates a manual subscription for the target user' do
      post path, params: { user_id: target_user.id }, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)

      ActsAsTenant.current_tenant = organisation
      sub = NotificationSubscription.find_by(user: target_user, subscribable: ticket)
      expect(sub).to be_present
      expect(sub.source).to eq('manual')
      expect(sub.subscribed_by).to eq(user)
    end

    it 'returns turbo stream response' do
      post path, params: { user_id: target_user.id }, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
    end
  end

  describe 'DELETE unsubscribe_other' do
    let(:path) do
      unsubscribe_other_organisation_project_ticket_subscription_path(
        organisation, project, ticket
      )
    end

    it 'removes a manual subscription' do
      sub = NotificationSubscription.subscribe_other(
        user: target_user, item: ticket, subscribed_by: user
      )

      delete path, params: { subscription_id: sub.id }, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      ActsAsTenant.current_tenant = organisation
      expect(NotificationSubscription.find_by(id: sub.id)).to be_nil
    end

    it 'rejects removal of non-manual subscriptions' do
      sub = NotificationSubscription.system_subscribe(
        user: target_user, item: ticket, source: 'assignee'
      )

      delete path, params: { subscription_id: sub.id }, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      ActsAsTenant.current_tenant = organisation
      expect(NotificationSubscription.find_by(id: sub.id)).to be_present
    end
  end

  describe 'GET available_users' do
    let(:path) do
      available_users_organisation_project_ticket_subscription_path(
        organisation, project, ticket
      )
    end

    it 'returns JSON list of unsubscribed users' do
      get path, headers: { 'Accept' => 'application/json' }

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json).to be_an(Array)

      user_ids = json.map { |u| u['id'] }
      expect(user_ids).to include(target_user.id)
    end

    it 'excludes already subscribed users' do
      NotificationSubscription.system_subscribe(user: target_user, item: ticket)

      get path, headers: { 'Accept' => 'application/json' }

      json = JSON.parse(response.body)
      user_ids = json.map { |u| u['id'] }
      expect(user_ids).not_to include(target_user.id)
    end

    it 'filters by search query' do
      target_user.update!(first_name: 'UniqueTestName')

      get path, params: { q: 'UniqueTestName' }, headers: { 'Accept' => 'application/json' }

      json = JSON.parse(response.body)
      expect(json.length).to be >= 1
      expect(json.first['name']).to include('UniqueTestName')
    end
  end
end
