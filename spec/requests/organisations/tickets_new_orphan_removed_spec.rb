# frozen_string_literal: true

require 'rails_helper'

# The standalone full-page "new ticket" view (new.html.erb) was orphaned and removed: the inline
# "New Ticket" modal on the index is the only entry point. These specs pin the replacement
# behaviour so the dead view cannot quietly come back and a stray non-Turbo POST can't 500.
RSpec.describe 'Tickets new (orphaned full-page view removed)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    sign_in user
  end

  it 'redirects GET /tickets/new to the index (the modal lives there)' do
    get new_organisation_project_ticket_path(organisation, project)

    expect(response).to redirect_to(organisation_project_tickets_path(organisation, project))
  end

  it 'redirects a failed non-Turbo HTML create to the index with the errors as a flash' do
    # title is required -> SaveTicket fails -> the HTML fallback must redirect, not render :new.
    post organisation_project_tickets_path(organisation, project), params: { ticket: { title: '' } }

    expect(response).to redirect_to(organisation_project_tickets_path(organisation, project))
    expect(flash[:alert]).to be_present
  end
end
