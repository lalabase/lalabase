# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Assistant draft context with stylesheets', type: :system do
  before { driven_by :selenium_chrome_headless_full }
  before { Prosopite.pause }
  after { Prosopite.resume }

  let(:organisation) do
    create(:organisation, assistant_enabled: true, ai_enabled: true,
                          ai_provider: 'openai', ai_access_token: 'sk-org-own-1234567890abcdef')
  end
  let(:user) { create(:user) }

  it 'shows an actionable offer in an empty chat and resets the selection for New chat' do
    ActsAsTenant.current_tenant = organisation
    role = create(:admin_role, organisation: organisation)
    create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    project = create(:project, organisation: organisation, name: 'Kundenportal')
    ticket = create(:ticket, project: project, organisation: organisation, creator: user,
                             title: 'Anmeldung am Kundenportal schlägt fehl')
    sign_in user
    visit organisation_project_ticket_path(organisation, project, ticket)
    find('#assistant-panel-trigger').click
    offer = '[data-assistant-panel-target="offer"]'
    expect(page).to have_css(offer, text: 'Anmeldung am Kundenportal')
    expect(page).to have_no_css('#assistant-panel-chat')
    find('[data-assistant-panel-target="offerTake"]').click
    expect(page).to have_css('[data-draft-reference]', text: 'Anmeldung am Kundenportal')
    expect(page).to have_no_css(offer)
    expect(ActsAsTenant.with_tenant(organisation) { Chat.count }).to eq(0)

    # Check actual geometry with CSS enabled, not only DOM ordering/classes.
    bounds = page.evaluate_script(<<~JS)
      (() => {
        const pill = document.querySelector('[data-draft-reference]').getBoundingClientRect()
        const field = document.querySelector('#assistant_panel textarea').getBoundingClientRect()
        return { bottom: pill.bottom, fieldTop: field.top, fieldBottom: field.bottom, height: innerHeight }
      })()
    JS
    expect(bounds['bottom']).to be <= bounds['fieldTop']
    expect(bounds['fieldBottom']).to be <= bounds['height']
    File.binwrite(ENV['ASSISTANT_DRAFT_SCREENSHOT'], page.driver.browser.screenshot_as(:png)) if ENV['ASSISTANT_DRAFT_SCREENSHOT']

    find('#assistant_panel a[title="Neuer Chat"]').click
    expect(page).to have_no_css('[data-draft-reference]')
    expect(page).to have_css(offer, text: 'Anmeldung am Kundenportal')
    expect(ActsAsTenant.with_tenant(organisation) { Chat.count }).to eq(0)
  end
end
