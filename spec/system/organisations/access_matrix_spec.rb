# frozen_string_literal: true

require 'rails_helper'

# [→E2E] Happy path for the org access matrix: an admin opens it, the client-side Stimulus
# filter narrows rows (by member name) and columns (by project), and a column deep-link
# leads to the editable project team page. Needs a JS driver — the filter is Stimulus, and
# CSS-faithful (_full) so `.am-hidden { display: none }` really hides elements.
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

    # Name filter narrows the rows: typing "alice" hides everyone else.
    find("input[data-access-matrix-filter-target='search']").set('alice')
    expect(page).to have_selector("tr[data-user-name='alice ant']", visible: :visible)
    expect(page).to have_selector("tr[data-user-name='bob bee']", visible: :hidden)

    # Clear the name filter so the column test is not confounded by hidden rows.
    find("input[data-access-matrix-filter-target='search']").set('')

    # Project filter narrows the columns: unchecking Apollo hides its column.
    find('summary', text: 'Projekte').click
    uncheck('Apollo')
    expect(page).to have_selector("th[data-project-id='#{apollo.id}']", visible: :hidden)
    expect(page).to have_selector("th[data-project-id='#{beacon.id}']", visible: :visible)

    # A column header is a deep-link to the editable project team page.
    click_link 'Beacon'
    expect(page).to have_current_path(organisation_project_project_permissions_path(organisation, beacon))
  end
end
