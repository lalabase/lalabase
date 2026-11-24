# frozen_string_literal: true

require 'rails_helper'

# What:  On a phone, the pencil of a booking in the time list opens its edit form, and the
#        change saved there reaches the booking.
# Type:  System spec with headless Chrome on a phone's viewport (390 px, below md, where the
#        list shows cards). spec/requests/organisations/time_sessions_edit_pencil_spec.rb
#        reads the markup.
# Why:   The phone's pencil was a link into the time list's own frame. The answer carried no
#        such frame, and the list turned into "Content missing" (lalabase/lalabase#263).
RSpec.describe 'Editing a booking on a phone', type: :system do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let!(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before do
    Prosopite.pause
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation,
                          role: create(:admin_role, organisation: organisation), active: true)
    end
    login_as(user, scope: :user)
    page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: 390, height: 844,
                                                                          deviceScaleFactor: 1, mobile: true)
  end

  # After the membership: the factory makes its creator a plain member otherwise.
  let!(:booking) do
    ActsAsTenant.with_tenant(organisation) do
      create(:time_session, organisation: organisation, project: project, creator: user,
                            duration: 60, occurred_on: Date.current, description: 'Alte Notiz')
    end
  end

  # The browser outlives the example: without this every later spec runs on a phone.
  after do
    page.driver.browser.execute_cdp('Emulation.clearDeviceMetricsOverride')
    page.driver.browser.execute_cdp('Emulation.setTouchEmulationEnabled', enabled: false)
    Prosopite.resume
  end

  let(:edit_title) { I18n.t('views.organisations.time_sessions.index_table.edit_tooltip') }
  let(:overlay) { "#time-session-overlay-#{booking.id}" }

  it 'opens the edit form from the pencil and saves the change' do
    visit organisation_time_sessions_path(organisation)
    wait_for_stimulus('[data-controller~="ticket-group"]', 'ticket-group')
    find('[data-action~="click->ticket-group#toggle"]').click

    # The pencil as the phone shows it, whatever it is wired with.
    find(%([data-ticket-group-target="sessions"] [title="#{edit_title}"])).click

    expect(page).to have_css(%(#{overlay} textarea[name="time_session[description]"]), wait: 10)
    expect(page).to have_no_css('#time_sessions_list_frame .turbo-frame-error')

    within(overlay) do
      find('textarea[name="time_session[description]"]').fill_in(with: 'Neue Notiz')
      find('button[type="submit"]').click
    end

    expect(page).to have_text(I18n.t('flash.time_sessions.updated'), wait: 10)
    expect(ActsAsTenant.with_tenant(organisation) { booking.reload.description }).to eq('Neue Notiz')
  end
end
