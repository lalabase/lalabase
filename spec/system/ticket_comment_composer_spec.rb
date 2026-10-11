# frozen_string_literal: true

require 'rails_helper'

# What:  The comment composer on a ticket: opens via the "Kommentar" button, saving a
#        comment closes it again and the next opening starts with an empty editor.
# Type:  System spec with headless Chrome (bug report 24.08.2026). Runs by hand:
#        spec/system is not in the CI list.
# Why:   Saving left the filled form standing (nothing ever re-rendered or hid the
#        collapse block); the fix streams a fresh composer from posts#create. Only a
#        real browser sees the collapse/reveal interplay.
RSpec.describe 'Ticket comment composer', type: :system do
  before { Prosopite.pause }
  after { Prosopite.resume }

  around do |example|
    adapter_was = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    ActiveJob::Base.queue_adapter = adapter_was
  end

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let!(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let!(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user, title: 'Fallbeschreibung', content: '<div>x</div>')
    end
  end

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation), active: true)
    end
    login_as(user, scope: :user)
  end

  it 'saves a comment, closes the composer and opens empty the next time' do
    visit organisation_project_tickets_path(organisation, project, ticket_id: ticket.id)

    composer = "#new-post-composer-#{ticket.id}"
    expect(page).to have_css("#{composer} [data-collapse-target='button']:not(.hidden)", wait: 10)
    within(composer) { click_on 'Kommentar' }

    editor = "#{composer} lexxy-editor[name='post[content]'] .lexxy-editor__content"
    expect(page).to have_css(editor, wait: 10)
    page.execute_script(<<~JS)
      const content = document.querySelector("#{editor}");
      content.focus();
    JS
    find(editor).send_keys('Erster Kommentar')
    within(composer) { find("button[type='submit']").click }

    # The comment lands in the timeline...
    expect(page).to have_content('Erster Kommentar', wait: 10)
    # ...and the composer is closed again: button visible, form hidden.
    expect(page).to have_css("#{composer} [data-collapse-target='button']:not(.hidden)", wait: 10)
    expect(page).to have_no_css("#{composer} [data-collapse-target='content']:not(.hidden)")

    # Opening again starts empty, the saved text is not still sitting in the editor.
    within(composer) { click_on 'Kommentar' }
    expect(page).to have_css(editor, wait: 10)
    expect(page.evaluate_script(%(document.querySelector("#{editor}").innerText))).not_to include('Erster Kommentar')
  end
end
