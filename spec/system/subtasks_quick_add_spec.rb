# frozen_string_literal: true

require 'rails_helper'

# The decomposition moment: on a parent ticket, type a sub-task title + Enter and a real child
# appears inline without a page reload, the field clears, and you can keep typing the next one.
# Request specs cover the server contract; this is the JS integration (Stimulus + Turbo Stream).
RSpec.describe 'Sub-tasks inline quick-add', type: :system do
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
  let(:parent)  { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, creator: user) } }

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  it 'creates a sub-task on Enter, appends the row inline and clears the field' do
    placeholder = I18n.t('views.organisations.tickets.shared.subtasks.add_placeholder')

    visit organisation_project_ticket_path(organisation, project, parent)

    # The section starts hidden; the "Unteraufgaben" row in the timeline menu shows it (#697).
    find('[data-timeline-filter-target="stateWord"]').click
    find('[data-timeline-filter-target="subtasksToggleButton"]').click

    fill_in placeholder, with: 'Texte liefern'
    find_field(placeholder).send_keys(:enter)

    # Child row appears inline (no reload) and the field is cleared for the next one.
    expect(page).to have_content('Texte liefern')
    expect(find_field(placeholder).value).to eq('')
    expect(ActsAsTenant.with_tenant(organisation) { parent.children.count }).to eq(1)
  end

  # The address names `items`, so the list frame's src equals it after the first reload. Each
  # assignment to src fetches, even an unchanged one. A frame.reload() behind it fetched again,
  # the duplicate guard in application.js blocked that, and the second row never came.
  it 'shows every new sub-task in the ticket list beside it, with no page change' do
    placeholder = I18n.t('views.organisations.tickets.shared.subtasks.add_placeholder')
    parent

    visit organisation_project_tickets_path(organisation, project, ticket_id: parent.id, items: 20)
    page.execute_script('window.__quickAddPageMark = true')

    within('#ticket_display_frame') do
      find('[data-timeline-filter-target="stateWord"]').click
      find('[data-timeline-filter-target="subtasksToggleButton"]').click
      find('[data-timeline-filter-target="stateWord"]').click

      fill_in placeholder, with: 'Texte liefern'
      find_field(placeholder).send_keys(:enter)
    end
    within('#tickets_list_frame') { expect(page).to have_content('Texte liefern') }

    # A person's pace: the same guard drops a second POST to this address inside 500 ms.
    sleep 0.6
    within('#ticket_display_frame') do
      fill_in placeholder, with: 'Bilder besorgen'
      find_field(placeholder).send_keys(:enter)
    end
    within('#tickets_list_frame') do
      expect(page).to have_content('Texte liefern')
      expect(page).to have_content('Bilder besorgen')
    end

    expect(page.evaluate_script('window.__quickAddPageMark === true')).to be(true)
  end
end
