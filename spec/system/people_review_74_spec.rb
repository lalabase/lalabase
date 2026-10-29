# frozen_string_literal: true

require 'rails_helper'

# Review of PR #74, two findings only a browser shows.
#
# P2: the rename of the members page's menu classes also renamed the dark
# rule of .members-danger, which the member panel still uses for its error
# line and "Mitglied entfernen". In dark mode that text fell back to the
# light red, 2.7:1 against the dark surface instead of 8.9:1.
#
# P3: .people-head > * stretched every child of the head, the phone's square
# "+" too (327 x 40 instead of 40 x 40). Measured at a phone's width: a
# desktop window leaves the phone layout after 200 ms (second review).
RSpec.describe 'People page, review of PR #74', type: :system do
  let(:organisation) { create(:organisation) }
  let(:admin) { create(:user, first_name: 'Anna', last_name: 'Admin') }
  let(:colleague) { create(:user, first_name: 'Carl', last_name: 'Kollege') }

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    role = create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE)
    create(:membership, user: admin, organisation: organisation, role: role, active: true)
    sign_in admin
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  it 'keeps the dark red of "Mitglied entfernen" in the member panel' do
    membership = create(:membership, user: colleague, organisation: organisation,
                                     role: create(:role, organisation: organisation), active: true)
    visit organisation_memberships_path(organisation)
    page.execute_script("localStorage.setItem('lb-theme', 'dark')")
    visit organisation_memberships_path(organisation, membership_id: membership.id)

    remove = find('.members-panel .members-danger', text: I18n.t('member_management.remove'))
    colors = page.evaluate_script(<<~JS, remove.native)
      (function (element) {
        const wanted = getComputedStyle(document.documentElement).getPropertyValue('--wash-danger-text').trim()
        const resolved = document.createElement('span')
        resolved.style.color = wanted
        document.body.append(resolved)
        const result = { dark: document.documentElement.classList.contains('dark'),
                         actual: getComputedStyle(element).color, expected: getComputedStyle(resolved).color }
        resolved.remove()
        return result
      })(arguments[0])
    JS

    expect(colors['dark']).to be(true)
    expect(colors['actual']).to eq(colors['expected'])
  end

  # On a phone for real: with the desktop window the viewport controller
  # switches the page to desktop after 200 ms and the phone's "+" is gone
  # (review of #74). The emulation is the one of mobile_shell_regressions_spec.
  it 'keeps the phone\'s "+" square' do
    page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    visit organisation_people_path(organisation)

    expect(page).to have_css('.people-mobile-grid .people-head__action')
    sleep 0.4 # past the viewport controller's 200 ms: the phone layout must still stand
    add = find('.people-mobile-grid .people-head__action')
    size = page.evaluate_script('(function (e) { const r = e.getBoundingClientRect(); return [r.width, r.height] })(arguments[0])',
                                add.native)
    expect(size[0]).to be_within(1).of(size[1])
  ensure
    page.driver.browser.execute_cdp('Emulation.clearDeviceMetricsOverride')
  end
end
