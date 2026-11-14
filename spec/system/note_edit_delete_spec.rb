# frozen_string_literal: true

require 'rails_helper'

# What:  Deleting a note from its edit form asks first; a "no" keeps the note,
#        a "yes" removes it from the list and empties the lane.
# Type:  System spec with headless Chrome. A request spec cannot see this: the
#        markup was complete, the browser dropped the question.
# Why:   Until 13.11.2026 the delete button was a form of its own INSIDE the edit
#        form (a `form:` button within `form_with`). The edit form arrives in a
#        Turbo Stream template, where the parser keeps a nested form, and Chrome
#        stops a nested form's submit event at the outer form. Turbo never saw
#        the submit, so its confirmation never ran: the browser posted the form
#        itself and one click deleted the note. The meeting edit form had the
#        same fault (spec/system/meetings_overview_spec.rb, "deletes from the lane").
RSpec.describe 'Deleting a note from its edit form', type: :system do
  before { Prosopite.pause }
  after { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let!(:note) do
    ActsAsTenant.with_tenant(organisation) do
      create(:note, project: project, organisation: organisation, creator: user, title: 'Protokoll Mai')
    end
  end

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation), active: true)
    end
    login_as(user, scope: :user)
  end

  it 'asks before it deletes, keeps the note on "no" and removes it on "yes"' do
    visit organisation_project_knowledge_index_path(organisation, project, note_id: note.id, type: 'all')
    find('a.note-edit-button', visible: :all).click
    delete = I18n.t('views.organisations.notes.note_edit.delete')
    expect(page).to have_link(delete, wait: 10)

    # The edit form holds no second form: that nesting is what lost the question.
    expect(page).to have_no_css('#note-card form form')

    dismiss_confirm { click_link delete }
    expect(page).to have_link(delete)
    expect(Note.unscoped.exists?(note.id)).to be(true)

    accept_confirm { click_link delete }
    expect(page).to have_text(I18n.t('views.organisations.knowledge.index.item_deleted_note'), wait: 10)
    expect(page).to have_no_css("tr[data-item-id='#{note.id}']")
    expect(Note.unscoped.exists?(note.id)).to be(false)
  end
end
