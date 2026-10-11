# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Notification deep link redirect', type: :request do
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

  # The recipient of a project notification is someone who can reach that project;
  # without the grant these examples describe an account shape that cannot exist.
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
             state: :queued)
    end
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
  end

  it 'redirects to ticket path' do
    get open_organisation_notification_path(organisation, notification)

    expect(response).to redirect_to(
      organisation_project_ticket_path(organisation, project, ticket, from_notification: true)
    )
  end

  it 'preserves the source parameter in the redirect' do
    get open_organisation_notification_path(organisation, notification, source: 'inbox')

    expect(response).to redirect_to(
      organisation_project_ticket_path(organisation, project, ticket,
                                       from_notification: true, source: 'inbox')
    )
  end

  # Regression: mobile-inbox infinite loop (2026-06-11). On the mobile switch
  # the viewport controller appends ?viewport=mobile to the /open URL. If the
  # redirect swallows the param, the ticket renders in desktop mode and the
  # client reloads /open endlessly (303 → desktop render → re-visit → 303 → …).
  describe 'viewport parameter propagation' do
    it 'preserves viewport=mobile in the redirect' do
      get open_organisation_notification_path(organisation, notification,
                                              source: 'inbox', viewport: 'mobile')

      expect(response).to redirect_to(
        organisation_project_ticket_path(organisation, project, ticket,
                                         from_notification: true, source: 'inbox', viewport: 'mobile')
      )
    end

    it 'preserves viewport=desktop in the redirect' do
      get open_organisation_notification_path(organisation, notification, viewport: 'desktop')

      expect(response).to redirect_to(
        organisation_project_ticket_path(organisation, project, ticket,
                                         from_notification: true, viewport: 'desktop')
      )
    end

    it 'drops viewport values outside the whitelist' do
      get open_organisation_notification_path(organisation, notification, viewport: 'evil"><script>')

      expect(response).to redirect_to(
        organisation_project_ticket_path(organisation, project, ticket, from_notification: true)
      )
    end
  end
end
