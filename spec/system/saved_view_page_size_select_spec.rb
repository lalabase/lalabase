# frozen_string_literal: true

require 'rails_helper'

# What: the "entries per page" select of the saved views, on their list and on
#       the results of one, shows the list again in the size chosen.
# Why:  until 2026-11-19 it saved the size and changed nothing on the page. The
#       bar named `smart-folders-list` as the frame to load: a plain <div> on the
#       list, no element at all on the results, and the script sets `src` on what
#       it finds. A request with `?items=5` was right all along, so only a
#       browser that changes the select shows it.
RSpec.describe 'Page-size select of the saved views', type: :system do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    sign_in user
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  # The option that names this size, in whatever language the page is in.
  def choose_page_size(size)
    find('.pagination-container select').find('option', text: /\A\s*#{size}\s/).select_option
  end

  it 'shows the list of saved views in the size chosen' do
    create_list(:smart_folder, 7, organisation: organisation, project: project, user: user)

    visit organisation_smart_folders_path(organisation)
    expect(page).to have_css('#smart-folders-list tbody tr', count: 7)

    choose_page_size(5)

    expect(page).to have_css('#smart-folders-list tbody tr', count: 5)
  end

  it 'shows the results of a saved view in the size chosen' do
    folder = create(:smart_folder, organisation: organisation, project: project, user: user, target_object_type: 'Note')
    group = create(:smart_folder_rule_group, smart_folder: folder)
    create(:smart_folder_rule, smart_folder_rule_group: group, field: 'title', operator: 'contains', value: 'Cap')
    7.times { |i| create(:note, title: "Cap #{i}", project: project, organisation: organisation, creator: user) }

    visit organisation_smart_folder_path(organisation, folder)
    expect(page).to have_css('#smart-folder-results [id^="note_"]', count: 7)

    choose_page_size(5)

    expect(page).to have_css('#smart-folder-results [id^="note_"]', count: 5)
  end
end
