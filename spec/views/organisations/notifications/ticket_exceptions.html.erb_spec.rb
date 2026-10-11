# frozen_string_literal: true

require 'rails_helper'

# Connected-block: the exceptions page must let the user reach the actual ticket.
# Proves each exception's info block links to the ticket detail page, that the
# inline unfollow action still ships alongside the link, and that the link is
# omitted when the ticket has no project (defensive guard against a nil project).
RSpec.describe 'organisations/notifications/ticket_exceptions', type: :view do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) do
    create(:ticket, organisation: organisation, project: project, title: 'Klick mich')
  end
  let(:subscription) { double('subscription', id: SecureRandom.uuid, updated_at: Time.current) }

  before do
    # Set after the suite-level before(:each) tenant reset, so factory creates see it.
    ActsAsTenant.current_tenant = organisation
    without_partial_double_verification do
      allow(view).to receive(:current_organisation).and_return(organisation)
    end
  end

  it 'links the ticket info block to the ticket detail page' do
    assign(:exceptions, [{ subscription: subscription, ticket: ticket, reason: :manual_follow }])
    render

    expect(rendered).to include(organisation_project_ticket_path(organisation, project, ticket))
    expect(rendered).to include('Klick mich')
  end

  it 'keeps the inline unfollow action alongside the link' do
    assign(:exceptions, [{ subscription: subscription, ticket: ticket, reason: :manual_follow }])
    render

    expect(rendered).to include(remove_ticket_exception_organisation_notifications_path(organisation))
    expect(rendered).to include(I18n.t('views.organisations.notifications.ticket_exceptions.unfollow'))
  end

  it 'omits the ticket link when the ticket has no project' do
    orphan = instance_double(Ticket, number: 99, title: 'Ohne Projekt', project: nil)
    assign(:exceptions, [{ subscription: subscription, ticket: orphan, reason: :manual_follow }])
    render

    expect(rendered).to include('Ohne Projekt')
    expect(rendered).not_to match(%r{href="[^"]*/tickets/})
  end
end
