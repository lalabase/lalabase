# frozen_string_literal: true

require 'rails_helper'

# Deleting a ticket from its edit form (the writing surface): the form must go away,
# the column collapses, the row leaves the list and the URL drops the ticket_id.
# The request spec (tickets_destroy_spec) pins the server streams; this is the
# Turbo + Stimulus integration that used to stall on a 500 after the delete.
RSpec.describe 'Ticket delete closes the detail column', type: :system do
  before { Prosopite.pause }
  after  { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation,
                          role: create(:admin_role, organisation: organisation), active: true)
    end
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let!(:ticket) do
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, creator: user, title: 'Wegwerf-Ticket') }
  end
  let!(:other_ticket) do
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, creator: user, title: 'Bleibt stehen') }
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  it 'removes the edit form, collapses the column and drops the ticket from list and URL' do
    visit organisation_project_tickets_path(organisation, project, ticket_id: ticket.id)

    within('#ticket_display_frame') do
      # The pencil is icon-only since round 8a - the title attribute carries
      # the words. The ticket title links to the edit form too (#758) and
      # carries the same title attribute; the pencil is the one without text.
      find(:link, title: I18n.t('views.organisations.tickets.ticket_header_show.edit_ticket'), exact_text: '').click
    end

    # The edit form opens as the writing surface above the page (#588), outside the column.
    within('turbo-frame#writing_surface') do
      expect(page).to have_field('ticket[title]', with: 'Wegwerf-Ticket')

      accept_confirm { click_link I18n.t('views.organisations.tickets.writing_surface.delete') }
    end

    # The edit form is gone, the column is collapsed.
    expect(page).to have_no_field('ticket[title]')
    expect(page).to have_css('.layout.two-column.hide-content')
    expect(page).to have_content(I18n.t('flash.tickets.deleted_notice'))

    # The list lost the row and keeps the other one; the URL no longer points at the deleted ticket.
    within('#tickets_list_frame') do
      expect(page).to have_no_content('Wegwerf-Ticket')
      expect(page).to have_content('Bleibt stehen')
    end
    expect(page.current_url).not_to include('ticket_id=')

    expect(ActsAsTenant.with_tenant(organisation) { Ticket.exists?(ticket.id) }).to be(false)
  end
end
