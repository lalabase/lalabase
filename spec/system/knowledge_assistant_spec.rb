# frozen_string_literal: true

require 'rails_helper'

# The knowledge objects in the assistant, end to end in a browser
# (doc/assistent_wissen_kontext_plan.md, step 3): the offer follows the open
# note, follows the switch to a document, goes away with the ✕, and a take
# before the first message lands as a draft reference. Stylesheets ON
# (selenium_chrome_headless_full): the ✕ and the closed lane are a matter of
# classes the layout controller writes, and the offer's absence has to be
# observed on a page that actually hides the column.
#
# ⚠️ Not in the CI (spec/system is not in guards.yml). Run by hand, and not in
# the same process as assistant_panel_layout_spec.
RSpec.describe 'Knowledge objects in the assistant', type: :system do
  before { driven_by :selenium_chrome_headless_full }
  before { Prosopite.pause }
  after { Prosopite.resume }

  let(:organisation) do
    create(:organisation, assistant_enabled: true, ai_enabled: true,
                          ai_provider: 'openai', ai_access_token: 'sk-org-own-1234567890abcdef')
  end
  let(:user) { create(:user) }

  let(:offer) { '[data-assistant-panel-target="offer"]' }

  def offer_hidden?
    page.evaluate_script(%((() => { const o = document.querySelector('#{offer}'); return !o || o.classList.contains('hidden') })()))
  end

  it 'offers the open note, follows the switch to a file, stops with the ✕, and takes a draft reference' do
    ActsAsTenant.current_tenant = organisation
    role = create(:admin_role, organisation: organisation)
    create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    project = create(:project, organisation: organisation, name: 'Kundenportal')
    note = create(:note, project: project, organisation: organisation, creator: user, title: 'Einarbeitung neuer Kollegen')
    document = create(:document, project: project, organisation: organisation, creator: user)
    document.update!(current_version: create(:document_version, document: document, organisation: organisation,
                                                                title: 'Angebot 2026'))
    sign_in user

    visit organisation_project_knowledge_index_path(organisation, project, note_id: note.id)
    find('#assistant-panel-trigger').click
    expect(page).to have_css(offer, text: 'Einarbeitung neuer Kollegen')

    # The ✕ hides the column by class and leaves the markup: the offer must
    # still go away. (With the panel AND the lane open the list is collapsed to
    # nothing -- the focus mode of layout.css -- so the ✕ is also what brings
    # the rows back within reach of a click.)
    find('[data-lane-close]').click
    expect(page).to have_css('.layout.hide-content')
    expect { offer_hidden? }.to eventually_be_true

    # The switch: the document's row opens the document in the lane, and the
    # offer follows without a click on the panel.
    find("[data-item-id='#{document.id}']").click
    expect(page).to have_css(offer, text: 'Angebot 2026')
    expect(page).to have_no_css(offer, text: 'Einarbeitung')

    # Take: the draft carries the document before any message is sent.
    find('[data-assistant-panel-target="offerTake"]').click
    expect(page).to have_css('[data-draft-reference]', text: 'Angebot 2026')
    expect { offer_hidden? }.to eventually_be_true
    expect(ActsAsTenant.with_tenant(organisation) { Chat.count }).to eq(0)

    # The lane's own button sets the note next to it, on the same draft.
    # ⚠️ Wait for the lane to be OPEN by class before clicking: Turbo inserts
    # the frame's content one repaint before it fires turbo:frame-load, and
    # only that event makes layout-toggle drop hide-content -- a click landed
    # in that gap finds the marker inside a still-closed lane. A person cannot
    # click inside one animation frame; a driver can.
    find('[data-lane-close]').click
    find("[data-item-id='#{note.id}']").click
    expect(page).to have_css('[data-lane-assistant]')
    expect(page).to have_no_css('.layout.hide-content')
    find('[data-lane-assistant]').click
    expect(page).to have_css('[data-draft-reference]', text: 'Einarbeitung neuer Kollegen')
    expect(page).to have_css('[data-draft-reference]', count: 2)
    expect { offer_hidden? }.to eventually_be_true
  end

  # A tiny polling matcher, so "hidden after the class flips" does not race the
  # rAF-coalesced observer.
  RSpec::Matchers.define :eventually_be_true do
    match do |block|
      20.times do
        return true if block.call

        sleep 0.1
      end
      false
    end

    supports_block_expectations
  end
end
