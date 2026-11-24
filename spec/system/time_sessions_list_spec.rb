# frozen_string_literal: true

require 'rails_helper'

# Regression guard: the chevron button of the ticket groups must expand/collapse
# the sessions. Previously the blanket button guard in
# ticket_group_controller#toggle blocked its own chevron — only the row click
# worked, the button with aria-label had no effect.
RSpec.describe 'Zeiten-Index Ticket-Gruppen', type: :system do
  before { Prosopite.pause }
  after  { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
  end

  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  let!(:time_session) do
    ActsAsTenant.with_tenant(organisation) do
      create(:time_session, organisation: organisation, project: project, ticket: nil,
                            creator: user, duration: 45, description: 'Chevron-Spec Eintrag')
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  # The chevron answers only once ticket-group has connected. On a cold browser the
  # click right after the visit came first, and the sessions stayed shut: alone, the
  # first example failed every run (spec/support/stimulus_helpers.rb).
  def visit_list(path)
    visit path
    wait_for_stimulus('[data-controller="ticket-group"]', 'ticket-group')
  end

  it 'klappt die Sessions über den Chevron-Button auf und wieder zu' do
    visit_list organisation_time_sessions_path(organisation, project_id_filter: project.id, date_range: 'all')

    group = find('[data-controller="ticket-group"]', match: :first)
    sessions = group.find('[data-ticket-group-target="sessions"]', visible: :all)
    expect(sessions[:class]).to include('hidden')

    chevron_button = group.find('button[aria-label]', visible: :all)

    chevron_button.click
    expect(group).to have_css('[data-ticket-group-target="sessions"]:not(.hidden)', visible: :all, wait: 3)

    chevron_button.click
    expect(group).to have_css('[data-ticket-group-target="sessions"].hidden', visible: :all, wait: 3)
  end

  # The JS unit spec pins WHERE an open row is kept; only a browser can show that
  # the controller actually asks. The bulk assignment answers with a redirect, so
  # without this every row the reader opened to decide what to select folds away
  # underneath them.
  it 'laesst eine aufgeklappte Zeile einen Seitenwechsel ueberleben' do
    path = organisation_time_sessions_path(organisation, project_id_filter: project.id, date_range: 'all')
    visit_list path

    group = find('[data-controller="ticket-group"]', match: :first)
    group.find('button[aria-label]', visible: :all).click
    expect(group).to have_css('[data-ticket-group-target="sessions"]:not(.hidden)', visible: :all, wait: 3)

    visit_list path

    expect(page).to have_css('[data-ticket-group-target="sessions"]:not(.hidden)', visible: :all, wait: 3)
  end

  it 'laesst eine wieder zugeklappte Zeile zugeklappt' do
    path = organisation_time_sessions_path(organisation, project_id_filter: project.id, date_range: 'all')
    visit_list path

    button = find('[data-controller="ticket-group"]', match: :first).find('button[aria-label]', visible: :all)
    button.click
    expect(page).to have_css('[data-ticket-group-target="sessions"]:not(.hidden)', visible: :all, wait: 3)
    button.click
    expect(page).to have_css('[data-ticket-group-target="sessions"].hidden', visible: :all, wait: 3)

    visit_list path

    expect(page).to have_css('[data-ticket-group-target="sessions"].hidden', visible: :all, wait: 3)
  end
end
