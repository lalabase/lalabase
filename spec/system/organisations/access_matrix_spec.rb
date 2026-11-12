# frozen_string_literal: true

require 'rails_helper'

# [→E2E] Happy path for the org access matrix: an admin opens it, the list search narrows
# the rows (it reloads the grid frame and writes q into the address), the project pill
# narrows the columns (projects[] in the address, kept by the search), and a column
# deep-link leads to the editable project team page. Real clicks in a real browser: the
# search opens from its magnifier and answers while typing.
RSpec.describe 'Access matrix', type: :system do
  before do
    Prosopite.pause
    driven_by(:selenium_chrome_headless_full)
  end
  after { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:member_role) { create(:role, organisation: organisation, title: 'member') }
  let(:admin) { create(:user) }

  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
    end
  end

  let!(:apollo) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Apollo') } }
  let!(:beacon) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Beacon') } }

  let!(:alice) do
    user = create(:user, first_name: 'Alice', last_name: 'Ant')
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: member_role, active: true)
      create(:project_permission, user: user, project: apollo, tickets_access: 'read_write')
    end
    user
  end

  let!(:bob) do
    user = create(:user, first_name: 'Bob', last_name: 'Bee')
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: member_role, active: true)
    end
    user
  end

  before { sign_in admin }

  it 'opens the matrix, filters rows + columns, and deep-links to the team page' do
    visit organisation_access_matrix_index_path(organisation)

    # The grid renders with both project columns as deep-links.
    expect(page).to have_css('.am-table')
    expect(page).to have_link('Apollo')
    expect(page).to have_link('Beacon')

    # The search opens from its magnifier and narrows the rows while typing.
    wait_for_stimulus('[data-fb-search]', 'search-disclosure')
    find('[data-fb-search-open-button]').click
    find('#access-matrix-search').set('alice')
    expect(page).to have_css('th.am-rowhead', text: 'Alice Ant')
    expect(page).to have_no_css('th.am-rowhead', text: 'Bob Bee')
    expect(page).to have_current_path(/q=alice/)

    # The project pill narrows the columns and keeps the search.
    find('[data-filter-pill="projects"] summary').click
    within('[data-filter-pill="projects"]') { click_link 'Beacon' }
    expect(page).to have_css("th[data-project-id='#{beacon.id}']")
    expect(page).to have_no_css("th[data-project-id='#{apollo.id}']")
    expect(page).to have_css('th.am-rowhead', text: 'Alice Ant')
    expect(page).to have_no_css('th.am-rowhead', text: 'Bob Bee')

    # A column header is a deep-link to the editable project team page.
    click_link 'Beacon'
    expect(page).to have_current_path(organisation_project_project_permissions_path(organisation, beacon))
  end
end
