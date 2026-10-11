# frozen_string_literal: true

require 'rails_helper'

# Regression guard: "Abbrechen" inside the smart-folder edit modal must close
# the modal client-side (like the X button). It used to be a link to
# smart_folders#show that navigated INSIDE the "modal" turbo frame — the show
# response contains no matching frame, so Turbo wiped the frame and rendered
# "Content missing" at the top of the page (Tickets AND Knowledge affected).
RSpec.describe 'Smart-Folder-Bearbeiten-Modal: Abbrechen', type: :system do
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

  let!(:note) do
    ActsAsTenant.with_tenant(organisation) do
      note = create(:note, title: 'Cancel-Spec Notiz', project: project, organisation: organisation, creator: user)
      tag = create(:tag, name: 'cancel-spec-tag', organisation: organisation)
      create(:tagging, tag: tag, taggable: note)
      note
    end
  end

  let!(:folder) do
    ActsAsTenant.with_tenant(organisation) do
      folder = create(:smart_folder, name: 'Cancel-Spec-Folder', organisation: organisation,
                                     project: project, user: user, target_object_type: 'Note')
      group = create(:smart_folder_rule_group, smart_folder: folder)
      create(:smart_folder_rule, smart_folder_rule_group: group,
                                 field: 'tag', operator: 'has', value: 'cancel-spec-tag')
      folder
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  it 'schließt das Modal ohne Content-missing im Modal-Frame' do
    visit organisation_project_knowledge_index_path(organisation, project, smart_folder_id: folder.id)

    # Open the edit modal from the menu at the active tab (S5): the pencil
    # next to the conditions is gone.
    find('[data-filter-bar-target="viewMenuButton"]', wait: 5).click
    click_on 'Im Expertenfilter öffnen…'
    expect(page).to have_css('[data-controller="smart-folder-modal"]', wait: 5)

    click_on 'Abbrechen'

    # Modal must be gone (its disappearance also serializes against a pending
    # frame navigation, so the Content-missing check below cannot pass early)
    expect(page).to have_no_css('[data-controller="smart-folder-modal"]', wait: 5)
    expect(page).to have_no_text('Content missing')

    # The empty modal frame must still be usable: reopening works
    find('[data-filter-bar-target="viewMenuButton"]').click
    click_on 'Im Expertenfilter öffnen…'
    expect(page).to have_css('[data-controller="smart-folder-modal"]', wait: 5)
  end
end
