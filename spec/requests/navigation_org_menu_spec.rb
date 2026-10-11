# frozen_string_literal: true

require 'rails_helper'

# What: Organisation switcher menu + "Verwaltung" sidebar entry in common/_navigation_application.
# Type: Request spec — the sidebar renders inside the app layout, so a GET against any org page
#       exercises it end-to-end (auth, tenant, layout cascade, permission gates).
# Why:  Pins the nav rebuild and its DECISION POINTS so a regression breaks a test:
#         - the org menu lists the user's orgs as one-click POST-switch forms, current one marked;
#         - the list is scoped to the user's ACTIVE memberships (no foreign/inactive orgs leak in);
#         - it is ordered alphabetically and capped at ORG_MENU_LIMIT (boundary n / n+1);
#         - the switcher appears for ANY multi-org user, invite/management gate independently;
#         - "Verwaltung" is its own sidebar entry, lit across ALL management tabs;
#         - the org dashboard nav item now reads "Dashboard", never "Übersicht".
#       The POST switch itself is covered by organisations_controller_spec (#set); here the menu is
#       only the form that drives it.
#
# NOTE on assertions: the menu content lives inside a collapsed <details>, so Capybara treats it as
# hidden — assertions against it pass `visible: :all` and read text with `.text(:all)`. The
# strict-subset gate relationship "may manage but not invite" is unreachable via a stored Permission
# (the finer gate actions like see_roles are not in Permission::CATEGORIES[:accounts]); that logic is
# pinned at the code level in spec/helpers/navigation_helper_spec.rb. Here we cover realizable states.
RSpec.describe 'Organisation switcher navigation', type: :request do
  # Build an org + a membership for `user`. Tenant is set BEFORE the org-scoped role/permissions/
  # membership are created (acts_as_tenant). `admin` => account_admin role; otherwise a plain
  # "member" role optionally carrying specific accounts permissions. `active:` toggles the membership
  # state so a dormant (deactivated) membership can be asserted OUT of the switcher.
  def org_with_membership(name:, user:, admin: false, permission_actions: [], active: true)
    org = create(:organisation, name: name)
    ActsAsTenant.with_tenant(org) do
      title = admin ? Role::ACCOUNT_ADMIN_TITLE : 'member'
      role  = create(:role, organisation: org, title: title)
      permission_actions.each do |action|
        create(:permission, role: role, category: 'accounts', action: action, allowed: true)
      end
      create(:membership, user: user, organisation: org, role: role, active: active)
    end
    org
  end

  def page_doc
    Capybara.string(response.body)
  end

  # Names of the orgs offered as switch forms, in rendered (DOM) order. .text(:all) because the
  # <details> is collapsed and its text is otherwise treated as hidden.
  def switcher_org_names
    page_doc.all("details form[action='#{set_organisation_path}'] button", visible: :all)
            .map { |button| button.text(:all).strip }
  end

  # CSS for the org-management gear in the header. Icon-only, so it is matched by its aria-label
  # (accessible name), not by visible text. Lives in the summary, which is always visible.
  def management_gear(org)
    "summary a[href='#{organisation_settings_path(org)}'][aria-label='#{I18n.t('navigation.management')}']"
  end

  let(:user) { create(:user) }

  describe 'multi-org admin' do
    let!(:acme)  { org_with_membership(name: 'Acme GmbH',  user: user, admin: true) }
    let!(:beta)  { org_with_membership(name: 'Beta AG',    user: user, admin: true) }
    let!(:gamma) { org_with_membership(name: 'Gamma e.V.', user: user, admin: true) }

    before do
      sign_in user
      get organisation_root_path(acme)
    end

    it 'lists every org as a one-click switch form with the current one marked' do
      expect(response).to have_http_status(:ok)
      expect(page_doc).to have_css("details[data-controller='details-autoclose']")
      expect(page_doc).to have_css("details form[action='#{set_organisation_path}']", count: 3, visible: :all)
      [acme, beta, gamma].each { |o| expect(response.body).to include(o.name) }
      # Exactly ONE row is marked current, and it is the current org — guards a "mark every row"
      # regression (the count catches mark-all; the text catches marking the wrong row).
      expect(page_doc).to have_css("details button[aria-current='true']", visible: :all, count: 1)
      expect(page_doc).to have_css("details button[aria-current='true']", text: acme.name, visible: :all)
    end

    it 'wires the floating-overlay behaviour (toggle handler + panel target)' do
      # Structural guard for the overlay: without these hooks the menu falls back to the in-flow
      # drawer and the sidebar scrollbar / content-jump returns. The positioning itself is
      # browser-only (see details_autoclose_controller#reposition) and not asserted here.
      expect(page_doc).to have_css("details[data-controller='details-autoclose'][data-action*='details-autoclose#onToggle']")
      expect(page_doc).to have_css("details ul[data-details-autoclose-target='panel']", visible: :all)
    end

    it 'offers "Alle Organisationen" and "Mitglied einladen" in the menu footer' do
      expect(page_doc).to have_css("details a[href='#{select_organisation_path}']",
                                   text: I18n.t('navigation.all_organisations'), visible: :all)
      expect(page_doc).to have_css(
        "details a[href='#{new_organisation_invitation_path(organisation_id: acme.id)}']",
        text: I18n.t('navigation.invite_member'), visible: :all
      )
    end

    it 'shows a "Verwaltung" gear in the org header and drops "Organisation wechseln"' do
      expect(page_doc).to have_css(management_gear(acme))
      expect(response.body).not_to include('Organisation wechseln')
    end
  end

  describe 'organisation list scoping (tenant isolation)' do
    # The switcher must list ONLY the user's ACTIVE-membership orgs. A foreign org (no membership)
    # and a dormant org (inactive membership) must never appear — catches a scope leak
    # (Organisation.all) or a dropped Membership.active merge.
    let!(:home)    { org_with_membership(name: 'Home GmbH',      user: user, admin: true) }
    let!(:also)    { org_with_membership(name: 'Also GmbH',      user: user, admin: true) }
    let!(:dormant) { org_with_membership(name: 'Dormant GmbH',   user: user, admin: true, active: false) }
    let!(:foreign) { create(:organisation, name: 'Foreign Zzz GmbH') } # user is NOT a member

    before do
      sign_in user
      get organisation_root_path(home)
    end

    it 'lists only the active-membership orgs, never a foreign or dormant one' do
      expect(response).to have_http_status(:ok)
      expect(switcher_org_names).to contain_exactly('Home GmbH', 'Also GmbH')
      expect(response.body).not_to include('Foreign Zzz GmbH')
      expect(response.body).not_to include('Dormant GmbH')
    end
  end

  describe 'organisation list ordering' do
    # Created in NON-alphabetical order so the test distinguishes alphabetical sorting from
    # insertion/PK order — a dropped `.reorder(LOWER(name))` would fall back to insertion order.
    let!(:zeta)  { org_with_membership(name: 'Zeta GmbH',  user: user, admin: true) }
    let!(:alpha) { org_with_membership(name: 'Alpha GmbH', user: user, admin: true) }
    let!(:mango) { org_with_membership(name: 'Mango GmbH', user: user, admin: true) }

    it 'lists organisations alphabetically regardless of creation order' do
      sign_in user
      get organisation_root_path(zeta)

      expect(switcher_org_names).to eq(['Alpha GmbH', 'Mango GmbH', 'Zeta GmbH'])
    end
  end

  describe 'single-org member without management rights' do
    let!(:org) { org_with_membership(name: 'Solo GmbH', user: user, admin: false) }

    before do
      sign_in user
      get organisation_root_path(org)
    end

    it 'renders the org name as static text with no switcher menu' do
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(org.name)
      expect(page_doc).to have_no_css("details[data-controller='details-autoclose']")
    end

    it 'shows neither "Verwaltung" nor "Mitglied einladen"' do
      expect(page_doc).to have_no_css("a[href='#{organisation_settings_path(org)}']")
      expect(response.body).not_to include(I18n.t('navigation.invite_member'))
    end
  end

  describe 'multi-org member without management rights' do
    # A plain member in two orgs must STILL get the switcher — its visibility is gated on
    # "multi-org OR may-invite", never AND. Catches a `||` -> `&&` regression on the menu gate.
    let!(:one) { org_with_membership(name: 'One GmbH', user: user, admin: false) }
    let!(:two) { org_with_membership(name: 'Two GmbH', user: user, admin: false) }

    before do
      sign_in user
      get organisation_root_path(one)
    end

    it 'renders the switcher with both orgs but no invite or management entry' do
      expect(response).to have_http_status(:ok)
      expect(page_doc).to have_css("details[data-controller='details-autoclose']")
      expect(page_doc).to have_css("details form[action='#{set_organisation_path}']", count: 2, visible: :all)
      expect(page_doc).to have_css("details a[href='#{select_organisation_path}']",
                                   text: I18n.t('navigation.all_organisations'), visible: :all)
      expect(response.body).not_to include(I18n.t('navigation.invite_member'))
      expect(page_doc).to have_no_css("a[href='#{organisation_settings_path(one)}']")
    end
  end

  describe 'non-admin user manager (storable manage_users permission)' do
    # manage_users is the only accounts permission the gate honours that a Permission row can
    # actually hold; it grants BOTH management and invite. Multi-org so the switcher renders.
    let!(:primary)   { org_with_membership(name: 'Primary GmbH', user: user, permission_actions: %w[manage_users]) }
    let!(:secondary) { org_with_membership(name: 'Secondary AG', user: user, admin: false) }

    before do
      sign_in user
      get organisation_root_path(primary)
    end

    it 'shows both the "Verwaltung" gear and "Mitglied einladen"' do
      expect(response).to have_http_status(:ok)
      expect(page_doc).to have_css(management_gear(primary))
      expect(page_doc).to have_css(
        "details a[href='#{new_organisation_invitation_path(organisation_id: primary.id)}']",
        text: I18n.t('navigation.invite_member'), visible: :all
      )
    end
  end

  describe 'more organisations than the menu cap' do
    let(:orgs) do
      (1..(NavigationHelper::ORG_MENU_LIMIT + 1)).map do |n|
        org_with_membership(name: format('Org %02d', n), user: user, admin: true)
      end
    end

    before do
      orgs # instantiate all n+1 orgs
      sign_in user
    end

    it 'caps the list at ORG_MENU_LIMIT rows and links to the full cockpit' do
      get organisation_root_path(orgs.min_by(&:name)) # current org sits inside the cap

      expect(page_doc).to have_css("details form[action='#{set_organisation_path}']",
                                   count: NavigationHelper::ORG_MENU_LIMIT, visible: :all)
      expect(response.body).to include('Org 07')      # last row still shown (n)
      expect(response.body).not_to include('Org 08')  # n+1 hidden behind "Alle Organisationen"
      expect(page_doc).to have_css("details a[href='#{select_organisation_path}']",
                                   text: I18n.t('navigation.all_organisations'), visible: :all)
    end

    # Documents the ACCEPTED trade-off (single alphabetical query, no current-org pinning): when the
    # current org sorts past the cap it is absent from the list and no row is marked — the summary
    # header still names it, and "Alle Organisationen" reaches the full list. Pinned so any future
    # "always include the current org" change is a conscious one that flips this test.
    it 'still renders the switcher (no marked row) when the current org sorts past the cap' do
      current = orgs.max_by(&:name) # 'Org 08', alphabetically last -> excluded from the top 7
      get organisation_root_path(current)

      expect(page_doc).to have_css("details[data-controller='details-autoclose']")
      expect(page_doc).to have_css("details form[action='#{set_organisation_path}']",
                                   count: NavigationHelper::ORG_MENU_LIMIT, visible: :all)
      expect(page_doc).to have_no_css("details button[aria-current='true']", visible: :all)
      expect(page_doc).to have_css('details summary', text: current.name)
      expect(page_doc).to have_css("details a[href='#{select_organisation_path}']",
                                   text: I18n.t('navigation.all_organisations'), visible: :all)
    end
  end

  describe 'management active-state and dashboard label' do
    let!(:org) { org_with_membership(name: 'Acme GmbH', user: user, admin: true) }

    before { sign_in user }

    it 'lights the "Verwaltung" gear on a management tab (members)' do
      get organisation_memberships_path(org)

      expect(response).to have_http_status(:ok)
      # Active gear carries the ink border; inactive uses border-cream-300 + a hover:border-ink.
      expect(page_doc).to have_css("#{management_gear(org)}.border-ink")
    end

    it 'does NOT light the "Verwaltung" gear on a non-management page (org dashboard)' do
      get organisation_root_path(org)

      # Present but inactive: the gear renders without the active ink border.
      expect(page_doc).to have_css(management_gear(org))
      expect(page_doc).to have_no_css("#{management_gear(org)}.border-ink")
    end

    it 'labels the org dashboard nav item "Dashboard", not "Übersicht"' do
      get organisation_root_path(org)

      expect(page_doc).to have_css("a[href='#{organisation_root_path(org)}'] span",
                                   text: 'Dashboard', exact_text: true)
      expect(page_doc).to have_no_css("a[href='#{organisation_root_path(org)}'] span", text: 'Übersicht')
    end
  end
end
