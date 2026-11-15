# frozen_string_literal: true

require 'rails_helper'

# What:  Cancel and Delete return to the frame that hosts the note editor, on
#        the Knowledge page and in either inbox. Delete still asks first.
# Type:  System spec with headless Chrome. A request spec cannot see this: the
#        markup was complete, the browser dropped the question.
# Why:   Until 13.11.2026 the delete button was a form of its own INSIDE the edit
#        form (a `form:` button within `form_with`). The edit form arrives in a
#        Turbo Stream template, where the parser keeps a nested form, and Chrome
#        stops a nested form's submit event at the outer form. Turbo never saw
#        the submit, so its confirmation never ran: the browser posted the form
#        itself and one click deleted the note. The meeting edit form had the
#        same fault (spec/system/meetings_overview_spec.rb, "deletes from the lane").
RSpec.describe 'Leaving the note edit form', type: :system, inbox_e2e: true do
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

  def open_editor
    visit entry_path
    find('a.note-edit-button', visible: :all).click
    expect(page).to have_css('#note-card form', wait: 10)
  end

  %i[knowledge organisation_inbox all_inboxes].each do |host|
    context "on #{host}" do
      let(:frame_id) { host == :knowledge ? 'knowledge_display_frame' : 'ticket_display_frame' }
      let(:entry_path) do
        if host == :knowledge
          organisation_project_knowledge_index_path(organisation, project, note_id: note.id, type: 'all')
        else
          row = project_event_row(organisation, project, 'note_created', recipient: user, actor: user,
                                                                         secondary: note, parameters: { 'note_title' => note.title })
          if host == :all_inboxes
            # Two memberships keep /inbox on the page above organisations.
            other = create(:organisation)
            ActsAsTenant.with_tenant(other) do
              create(:membership, user: user, organisation: other, role: create(:admin_role, organisation: other), active: true)
            end
            all_inboxes_path(notification: row.id)
          else
            organisation_notifications_path(organisation, notification: row.id)
          end
        end
      end

      it 'cancels into the same frame without saving or leaving the page' do
        open_editor
        address = page.current_url
        fill_in 'note_title', with: 'Unsaved title'

        click_link I18n.t('views.organisations.notes.note_edit.cancel')

        expect(page).to have_css("##{frame_id} [data-lane-title]", text: 'Protokoll Mai')
        expect(page).to have_no_css('#note-card')
        expect(page.current_url).to eq(address)
        expect(note.reload.title).to eq('Protokoll Mai')
      end

      it 'asks before it deletes, keeps the note on "no" and clears the editor on "yes"' do
        open_editor
        delete = I18n.t('views.organisations.notes.note_edit.delete')
        expect(page).to have_link(delete)

        # The edit form holds no second form: that nesting is what lost the question.
        expect(page).to have_no_css('#note-card form form')

        dismiss_confirm { click_link delete }
        expect(page).to have_link(delete)
        expect(Note.unscoped.exists?(note.id)).to be(true)

        accept_confirm { click_link delete }
        expect(page).to have_css("##{frame_id}", text: I18n.t('views.organisations.knowledge.index.item_deleted_note'), wait: 10)
        expect(page).to have_no_css('#note-card')
        expect(page).to have_no_css("tr[data-item-id='#{note.id}']")
        expect(Note.unscoped.exists?(note.id)).to be(false)
      end
    end
  end
end
