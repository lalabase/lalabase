# frozen_string_literal: true

require 'rails_helper'

# Regression guard for the "move ticket" button in the ticket-header action bar.
#
# The trigger carries data-action="click->move-ticket-modal#open". A Stimulus
# action only binds when the element (or an ANCESTOR) carries the matching
# data-controller. Commit 0ff13862 extracted the trigger into the action-bar
# partial but left data-controller="move-ticket-modal" wrapping only the modal,
# turning the trigger into an out-of-scope sibling -> clicking it did nothing.
#
# This spec asserts the structural invariant (trigger is a DESCENDANT of the
# controller element), not just that both fragments exist on the page.
RSpec.describe 'Move-ticket modal Stimulus scope (ticket detail)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end
  let(:ticket) do
    ActsAsTenant.current_tenant = organisation
    create(:ticket, project: project, organisation: organisation, creator: user)
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation,
                        role: create(:admin_role, organisation: organisation))
    sign_in user
  end

  it 'renders the move trigger inside the move-ticket-modal controller scope' do
    get organisation_project_ticket_path(organisation, project, ticket)
    expect(response).to have_http_status(:ok)

    doc = Nokogiri::HTML(response.body)

    # Sanity: an account_admin may move the ticket, so a trigger is rendered.
    trigger = doc.at_css('[data-action*="move-ticket-modal#open"]')
    expect(trigger).to be_present,
                       'expected a move trigger (data-action click->move-ticket-modal#open) on the page'

    # Regression: the controller element must exist and must CONTAIN the trigger.
    scope = doc.at_css('[data-controller~="move-ticket-modal"]')
    expect(scope).to be_present, 'expected a data-controller="move-ticket-modal" element'
    expect(scope.at_css('[data-action*="move-ticket-modal#open"]')).to be_present,
                                                                       'move trigger must be a descendant of the move-ticket-modal controller, ' \
                                                                       'otherwise Stimulus never binds #open and the button is dead'

    # The modal target lives in the same scope (so #open can unhide it).
    expect(scope.at_css('[data-move-ticket-modal-target="modal"]')).to be_present

    # Page-wide watchdog: lazy t('.') in the header partial resolves WITHOUT
    # the views prefix, and missing keys rendered as humanized names for
    # weeks before anyone noticed ("Attach File", "Back To List").
    expect(response.body).not_to include('translation_missing')
  end
end
