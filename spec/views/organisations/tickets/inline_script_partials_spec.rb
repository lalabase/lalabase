# frozen_string_literal: true

# What: Render specs for the three script partials tickets#create / #destroy append to the
#   body (extracted from controller heredocs in S4; modal handling dropped in Paket 3,
#   because the writing surface is closed by clearing turbo-frame#modal).
# Why: pins the rendered OUTPUT (script markers + interpolated locals) so the partials
#   stay what the controller expects. The destroy wiring itself is request-tested in
#   tickets_destroy_spec.rb.

require 'rails_helper'

RSpec.describe 'organisations/tickets inline-script partials', type: :view do
  it 'create_redirect_dashboard: goes to the new ticket (no modal left to close)' do
    render partial: 'organisations/tickets/create_redirect_dashboard', locals: { redirect_url: '/org/o/projects/p/tickets?ticket_id=abc' }

    # redirect_url is JSON-encoded (erblint's javascript-interpolation rule)
    expect(rendered).to include('window.location.href = "/org/o/projects/p/tickets?ticket_id=abc"')
    expect(rendered).not_to include('data-modal-target')
  end

  it 'create_show_index: shows the content column and highlights the new row (no modal left to close)' do
    render partial: 'organisations/tickets/create_show_index', locals: { ticket_id: 'ticket-abc-123' }

    expect(rendered).not_to include('data-modal-target')
    expect(rendered).to include('show-content')
    expect(rendered).to include('const ticketId = "ticket-abc-123"')
    expect(rendered).to include('tr[data-ticket-id="')
    expect(rendered).to include('selected-row')
  end

  it 'destroy_close: collapses the content column via layout-toggle (notice comes from the flash stream)' do
    render partial: 'organisations/tickets/destroy_close'

    expect(rendered).to include("getControllerForElementAndIdentifier(layoutToggleElement, 'layout-toggle')")
    expect(rendered).to include('closeContent()')
    expect(rendered).to include('hide-content')
    expect(rendered).not_to include(I18n.t('flash.tickets.deleted_notice'))
  end
end
