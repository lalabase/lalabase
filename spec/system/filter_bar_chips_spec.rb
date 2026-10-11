# frozen_string_literal: true

require 'rails_helper'

# Regression guard: with an active smart folder, the FilterBar must render the
# condition row (one pill per condition below the view tabs) client-side. A
# ReferenceError in chip_renderer once crashed the entire filter-bar controller
# as soon as a folder was active: the row stayed empty, editing and removing
# impossible (tickets AND knowledge affected). The whole row is built in
# JavaScript, so only a browser run can see it.
RSpec.describe 'FilterBar Chip-Zeile bei aktivem Smart Folder', type: :system do
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
      note = create(:note, title: 'Chip-Spec Notiz', project: project, organisation: organisation, creator: user)
      tag = create(:tag, name: 'chip-spec-tag', organisation: organisation)
      create(:tagging, tag: tag, taggable: note)
      note
    end
  end

  let!(:folder) do
    ActsAsTenant.with_tenant(organisation) do
      folder = create(:smart_folder, name: 'Chip-Spec-Folder', organisation: organisation,
                                     project: project, user: user, target_object_type: 'Note')
      group = create(:smart_folder_rule_group, smart_folder: folder)
      create(:smart_folder_rule, smart_folder_rule_group: group,
                                 field: 'tag', operator: 'has', value: 'chip-spec-tag')
      folder
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  it 'rendert die Chips des aufgeloesten Folders auf der Knowledge-Seite' do
    visit organisation_project_knowledge_index_path(organisation, project, smart_folder_id: folder.id)
    # Since 20a the pill row is the editing state: first "ändern".
    expect(page).to have_css('[data-fb-prose]', wait: 5)
    click_on 'ändern'

    within('#filter-bar-chips') do
      expect(page).to have_text('chip-spec-tag', wait: 5)
      # One pill per condition (F13): the category, the value as a tile, the
      # chevron that says the pill opens. Nothing lime, no coloured border.
      expect(page).to have_css('[data-condition="tag"] [data-value-tile]', text: 'chip-spec-tag')
      expect(page).to have_css('[data-condition="tag"] [data-chevron]')
      expect(page).not_to have_css('[class*="lime"]')
      # F19 left the condition row (finding 15): a value carries no cross at
      # any width, it is taken away one level up. Not "hidden here": absent.
      expect(page).not_to have_css('[data-condition="tag"] [data-fb-remove]', visible: :all)
    end
    # The active view is a tab, marked by underline and weight (F10)
    expect(page).to have_css('a[role="tab"][aria-selected="true"]', text: 'Chip-Spec-Folder')
    expect(page).not_to have_css('button[data-smart-folder-id]')
    # Nothing differs from the view: no dot, no save row
    expect(page).not_to have_css('[data-filter-bar-target="unsavedDot"]', visible: :visible)
    expect(page).not_to have_css('[data-filter-bar-target="saveRow"]', visible: :visible)
  end

  # The save row (F23) and the way back (F25): all of it is JavaScript over the
  # address, so only a browser can see it. A condition the reader added to the
  # saved view shows the amber dot on the tab and the row that names the
  # change; "Verwerfen" asks nothing and reloads the view as saved; the flash
  # on that page carries "Rückgängig", which brings tab and conditions back.
  it 'zeigt die Speicherzeile mit dem benannten Wert, verwirft ohne Rückfrage und holt per Rückgängig zurück' do
    visit organisation_project_knowledge_index_path(organisation, project, smart_folder_id: folder.id, filter: { creator: [user.id] })

    expect(page).to have_css('[data-filter-bar-target="saveRow"]', text: /„#{Regexp.escape(user.display_name)}“ kam dazu\./, wait: 5)
    expect(page).to have_css('a[role="tab"][aria-selected="true"] [data-filter-bar-target="unsavedDot"]', visible: :visible)
    # What the change does to the list stands next to what it was (20a, § 8).
    # The number costs nothing: the list counted it for its pager anyway, and
    # the bar reads it from the reloaded frame.
    expect(page).to have_css('[data-filter-bar-target="saveRow"] [data-fb-hits]', text: '1')
    click_on 'ändern'
    expect(page).to have_css('[data-condition="creator"] [data-value-tile]', text: user.display_name)

    within('[data-filter-bar-target="saveRow"]') { click_on 'Verwerfen' }

    expect(page).to have_no_css('[data-condition="creator"]', wait: 5)
    expect(page).not_to have_css('[data-filter-bar-target="saveRow"]', visible: :visible)
    expect(page).to have_css('[data-controller="neo-flash"]', text: 'Änderung verworfen', wait: 5)

    click_on 'Rückgängig'

    # The sentence says "mir", not the user's own name: the filter is on the
    # signed-in user, who does not read about themselves in the third person.
    expect(page).to have_css('[data-fb-prose]', text: 'von mir erstellt', wait: 5)
    expect(page).to have_css('[data-filter-bar-target="saveRow"]', text: /kam dazu/)
    expect(page).to have_css('a[role="tab"][aria-selected="true"]', text: 'Chip-Spec-Folder')
  end

  # A view the bar saved with a date preset reads back as that preset (the round
  # trip of doc/filter_datumsvorgaben_rundlauf_plan.md): the pill is editable and
  # the save row offers "Änderung speichern". Before, "diese Woche" was saved as
  # a frozen day count the bar could not read, and the row offered only
  # "Verwerfen" (D4 of the S1 to S4 plan, meant for expert-made rules).
  it 'liest eine mit „diese Woche“ gesicherte Ansicht zurück und bietet nach einer Änderung das Speichern an' do
    saved = ActsAsTenant.with_tenant(organisation) do
      Actors::SaveSmartFolderFromFilters.call(
        project: project, current_user: user, filter_params: { 'created_at' => ['this_week'] },
        operator_params: {}, name: 'Diese Woche', target_object_type: 'Note'
      ).resource
    end

    visit organisation_project_knowledge_index_path(organisation, project, smart_folder_id: saved.id, filter: { creator: [user.id] })

    expect(page).to have_css('[data-filter-bar-target="saveRow"]', text: 'Änderung speichern', wait: 5)
    click_on 'ändern'
    expect(page).to have_css('[data-condition="created_at"] [data-chevron]')
    expect(page).to have_no_css('[data-complex-rule]')
  end

  # The menu at the active tab (S5): rename in the layer, the tab and the
  # record follow; delete asks once, then the base view with the flash and no
  # way back. Both are fetches with JSON answers the controller reads itself.
  it 'benennt die Ansicht in der Ebene um; Reiter und Datensatz folgen' do
    visit organisation_project_knowledge_index_path(organisation, project, smart_folder_id: folder.id)

    find('[data-filter-bar-target="viewMenuButton"]', wait: 5).click
    click_on 'Umbenennen'
    find('[data-filter-bar-target="renameInput"]').set("Ganz eilig\n")

    expect(page).to have_css('a[role="tab"][aria-selected="true"]', text: 'Ganz eilig', wait: 5)
    expect(page).to have_css('[data-controller="neo-flash"]', text: 'Umbenannt')
    expect(folder.reload.name).to eq('Ganz eilig')
  end

  # 20a, § 4: without the path through a copy, whoever changes a shared view
  # overwrites what colleagues work with. The copy then belongs to whoever
  # created it, and the list switches to it right away.
  it 'dupliziert die Ansicht und öffnet die Liste auf der Kopie' do
    visit organisation_project_knowledge_index_path(organisation, project, smart_folder_id: folder.id)

    find('[data-filter-bar-target="viewMenuButton"]', wait: 5).click
    click_on 'Duplizieren'

    copy_name = I18n.t('smart_folders.copy_of', name: folder.name)
    expect(page).to have_css('a[role="tab"][aria-selected="true"]', text: copy_name, wait: 5)
    expect(SmartFolder.where(name: copy_name).count).to eq(1)
    # The original stays untouched next to it.
    expect(folder.reload.name).to eq('Chip-Spec-Folder')
  end

  it 'löscht die Ansicht nach einer Rückfrage und landet mit Hinweis auf der Basisansicht' do
    visit organisation_project_knowledge_index_path(organisation, project, smart_folder_id: folder.id)

    find('[data-filter-bar-target="viewMenuButton"]', wait: 5).click
    dismiss_confirm(/Chip-Spec-Folder/) { click_on 'Ansicht löschen' }
    expect(SmartFolder.exists?(folder.id)).to be true

    accept_confirm(/Chip-Spec-Folder/) { click_on 'Ansicht löschen' }

    expect(page).to have_current_path(organisation_project_knowledge_index_path(organisation, project), wait: 5)
    expect(page).to have_css('[data-controller="neo-flash"]', text: 'gelöscht', wait: 5)
    expect(page).not_to have_link('Rückgängig')
    expect(page).not_to have_css('a[role="tab"]', text: 'Chip-Spec-Folder')
    expect(SmartFolder.exists?(folder.id)).to be false
  end

  # The sentence is the resting state (20a, S1): a filter is read many times and
  # changed once. The pills wait in their row until somebody says "ändern", a
  # value in the sentence opens its own layer without any change of form, and
  # "fertig" fetches the sentence back. All of it is JavaScript over a frame,
  # so only a browser can see it.
  it 'liest die Bedingungen als Satz und wechselt erst auf "ändern" in die Pillen' do
    visit organisation_project_knowledge_index_path(organisation, project, smart_folder_id: folder.id)

    expect(page).to have_css('[data-fb-prose]', text: /Nur Einträge, die das Etikett chip-spec-tag haben\./, wait: 5)
    expect(page).not_to have_css('[data-condition="tag"]', visible: :visible)

    click_on 'ändern'

    expect(page).to have_css('[data-condition="tag"] [data-value-tile]', text: 'chip-spec-tag', wait: 3)
    expect(page).not_to have_css('[data-fb-prose]', visible: :visible)

    click_on 'fertig'

    expect(page).to have_css('[data-fb-prose]', text: /chip-spec-tag/, wait: 5)
    expect(page).not_to have_css('[data-condition="tag"]', visible: :visible)
  end

  it 'oeffnet aus einem Wort des Satzes die Ebene dieses Feldes, ohne die Form zu wechseln' do
    visit organisation_project_knowledge_index_path(organisation, project, smart_folder_id: folder.id)
    expect(page).to have_css('[data-fb-prose]', wait: 5)

    find('[data-fb-prose] button[data-category="tag"]').click

    expect(page).to have_css('[data-filter-bar-target="valueMenu"]:not(.hidden)', wait: 3)
    # No change of form: the sentence stays, the pill row stays away.
    expect(page).to have_css('[data-fb-prose]', visible: :visible)
    expect(page).not_to have_css('[data-condition="tag"]', visible: :visible)
  end

  # Without a condition nothing stands there, not even a single word. The bug
  # this catches was in the browser, not on the server: the component hid the
  # row correctly, and the JavaScript revealed it again because it asked for
  # the paragraph instead of a sentence. On "Alle Einträge" a bare "ändern"
  # then stood below the tabs.
  it 'zeigt auf der Basisansicht keine Bedingungszeile und kein nacktes Wort' do
    visit organisation_project_knowledge_index_path(organisation, project)

    expect(page).to have_css('a[role="tab"][aria-selected="true"]', wait: 5)
    expect(page).not_to have_css('[data-fb-prose]', visible: :visible)
    expect(page).not_to have_css('[data-filter-bar-target="editWord"]', visible: :visible)
    expect(page).not_to have_css('[data-filter-bar-target="sentenceRow"]', visible: :visible)
    # The way in is "+ Filter" at the top, and it is there.
    expect(page).to have_css('[data-filter-bar-target="filterButton"]', visible: :visible)
  end

  # 20a, § 9: no modal for one word. The name comes up in the row that is
  # already there, and it is derived from the conditions and preselected: the
  # quickest answer is the Enter key.
  it 'benennt eine neue Ansicht in der Zeile, nicht in einem Modal' do
    visit organisation_project_knowledge_index_path(organisation, project, filter: { tag: ['chip-spec-tag'] })

    expect(page).to have_css('[data-filter-bar-target="saveRow"]', wait: 5)
    click_on 'Als Ansicht sichern'

    expect(page).to have_css('[data-fb-naming]', wait: 3)
    expect(page).not_to have_css('#filter-bar-save-modal')
    field = find('input[name="smart_folder_name"]')
    expect(field.value).to eq('chip-spec-tag')

    field.set('Kundensachen')
    field.send_keys(:enter)

    expect(page).to have_css('a[role="tab"][aria-selected="true"]', text: 'Kundensachen', wait: 5)
    expect(SmartFolder.where(name: 'Kundensachen').count).to eq(1)
  end

  # 20a, § 10: everything in the bar is reachable by keyboard, and the focus
  # goes where the pointer would. Escape leaves a layer, one step at a time.
  it 'ist mit der Tastatur zu bedienen, vom Satz bis in die Ebene und zurueck' do
    visit organisation_project_knowledge_index_path(organisation, project, smart_folder_id: folder.id)
    expect(page).to have_css('[data-fb-prose]', wait: 5)

    # A value in the sentence is a target, not text: reachable by keyboard and
    # opened with Enter.
    value = find('[data-fb-prose] button[data-category="tag"]')
    value.send_keys(:enter)

    expect(page).to have_css('[data-filter-bar-target="valueMenu"]:not(.hidden)', wait: 3)
    # The focus is in the layer, no longer on the word: otherwise you type into nothing.
    expect(page.evaluate_script('document.activeElement.closest(\'[data-filter-bar-target="valueMenu"]\') !== null')).to be true

    # Escape out of the layer, not via the body: otherwise the click on body
    # takes the focus away first and the question would be a different one.
    page.driver.browser.switch_to.active_element.send_keys(:escape)

    expect(page).to have_css('[data-filter-bar-target="valueMenu"].hidden', visible: :all)
    # And the focus comes back to where it came from.
    expect(page.evaluate_script('document.activeElement.dataset.category')).to eq('tag')
  end

  # 20a, § 6: in the editing state the way to one more condition stands where
  # the conditions are, not in the tab row. Two triggers, one layer, and it
  # opens where the trigger stands.
  it 'nimmt aus der Pillenzeile eine Bedingung dazu, an Ort und Stelle' do
    visit organisation_project_knowledge_index_path(organisation, project, smart_folder_id: folder.id)
    expect(page).to have_css('[data-fb-prose]', wait: 5)
    click_on 'ändern'

    trigger = find('[data-fb-add-condition]')
    trigger.click

    menu = find('[data-filter-bar-target="filterMenu"]:not(.hidden)')
    expect(menu).to have_css('[role="menuitem"][data-category="creator"]')
    # The layer hangs on the trigger, not on the "+ Filter" at the top right.
    menu_left = page.evaluate_script("document.querySelector('[data-filter-bar-target=\"filterMenu\"]').getBoundingClientRect().left")
    trigger_left = page.evaluate_script("document.querySelector('[data-fb-add-condition]').getBoundingClientRect().left")
    expect(menu_left).to be_within(20).of(trigger_left)
  end

  # The filter selection behind "+ Filter" (Prüfstand F23, 07.09.2026). All of
  # it is JavaScript, so only a browser can see it: the layer says which layer
  # it is and holds its ways out, it marks the categories that already carry a
  # condition, the condition being built stands as an empty pill so the layer
  # keeps its anchor, ticking a value does not close it (F29), and Escape goes
  # one step back (F36) before it goes out.
  it 'oeffnet die Filterauswahl mit Kopf, markiert Benutztes und bleibt beim Waehlen offen' do
    visit organisation_project_knowledge_index_path(organisation, project, smart_folder_id: folder.id)
    expect(page).to have_css('[data-fb-prose]', wait: 5)

    find('[data-filter-bar-target="filterButton"]').click

    within('[data-filter-bar-target="filterMenu"]') do
      expect(page).to have_css('[data-fb-head]')
      expect(page).to have_css('[data-fb-close]')
      expect(page).to have_css('[role="menu"] [role="menuitem"][data-category="creator"]')
      # The saved condition of this view makes its category one in use
      expect(page).to have_css('[role="menuitem"][data-category="tag"] [data-fb-in-use]')
      expect(page).not_to have_css('[role="menuitem"][data-category="creator"] [data-fb-in-use]')
    end

    find('[role="menuitem"][data-category="creator"]').click

    within('[data-filter-bar-target="valueMenu"]') do
      # Two doors, and they go to different places: one step back, and out
      expect(page).to have_css('[data-fb-back]')
      expect(page).to have_css('[data-fb-close]')
    end
    # The condition being built stands, quiet and without a value
    expect(page).to have_css('[data-condition="creator"]', text: 'nichts gewählt')

    within('[data-filter-bar-target="valueMenu"]') { first('input[type="checkbox"]').click }

    expect(page).to have_css('[data-condition="creator"] [data-value-tile]', wait: 5)
    expect(page).to have_css('[data-filter-bar-target="valueMenu"]:not(.hidden)')

    find('body').send_keys(:escape)

    expect(page).to have_css('[data-filter-bar-target="filterMenu"]:not(.hidden)')
    expect(page).to have_css('[data-filter-bar-target="valueMenu"].hidden', visible: :all)
    # The mark is a statement about now, so it was read again on the way back
    expect(page).to have_css('[role="menuitem"][data-category="creator"] [data-fb-in-use]')

    find('body').send_keys(:escape)

    expect(page).to have_css('[data-filter-bar-target="filterMenu"].hidden', visible: :all)
  end

  # Rule 7 (S8): narrow, nothing is invented and nothing shrunk. The bar
  # measures its own width (container query), so a 390 px window is enough
  # to see it: the search is the magnifier and opens at the right end of the
  # tab row (user, 07.09.2026; filter_bar.css), the tabs keep the rest of the
  # row and stay reachable, the plus stands alone, the layer
  # spans the bar, and the close of that layer grows to a thumb's 32 px.
  it 'faltet sich bei 390 px nach Regel 7 zusammen, ohne eine neue Form' do
    page.driver.browser.manage.window.resize_to(390, 800)
    visit organisation_project_knowledge_index_path(organisation, project, smart_folder_id: folder.id)
    expect(page).to have_css('[data-fb-prose]', wait: 5)
    click_on 'ändern'
    expect(page).to have_css('[data-condition="tag"]', wait: 3)

    expect(page).to have_css('[data-fb-search-open-button]', visible: :visible)
    expect(page).not_to have_css('[data-filter-bar-target="searchInput"]', visible: :visible)
    expect(page).not_to have_css('[data-fb-add-label]', visible: :visible)

    find('[data-condition="tag"] [data-fb-open]').click
    expect(page).to have_css('[data-filter-bar-target="valueMenu"]:not(.hidden)', wait: 3)
    width = page.evaluate_script('document.querySelector(\'[data-filter-bar-target="valueMenu"]\').getBoundingClientRect().width')
    bar = page.evaluate_script('document.querySelector(\'.filter-bar\').getBoundingClientRect().width')
    expect(width).to be > bar - 40
    expect(page.evaluate_script('document.activeElement.closest(\'[data-filter-bar-target="valueMenu"]\') !== null')).to be true

    find('[data-filter-bar-target="valueMenu"] button[aria-label="Schließen"]').click
    find('[data-fb-search-open-button]').click
    expect(page).to have_css('[data-filter-bar-target="searchInput"]', visible: :visible, wait: 3)
    expect(page.evaluate_script('document.activeElement === document.querySelector(\'[data-filter-bar-target="searchInput"]\')')).to be true
    # Beside, not over: the open field takes the right end of the row and the
    # tab strip keeps what lies left of it; the strip scrolls, so the active tab
    # is still there to tap.
    strip_right = page.evaluate_script('document.querySelector(\'[data-filter-bar-target="tabStrip"]\').getBoundingClientRect().right')
    field_left = page.evaluate_script('document.querySelector(\'[data-fb-search]\').getBoundingClientRect().left')
    expect(field_left).to be >= strip_right
    find('a[role="tab"][aria-selected="true"]').click
    # The tab click reloads, and reloaded means the resting state: the sentence is there.
    expect(page).to have_css('[data-fb-prose]', wait: 5)
  ensure
    page.driver.browser.manage.window.resize_to(1920, 1080)
  end
end
