# frozen_string_literal: true

require 'rails_helper'

# What: on a phone the fixed head (layouts/_mobile_header) names the page, and
#       the page's own head (NeoTitleBoxComponent) says nothing the fixed head
#       already says. Outside a project: one visible heading, the fixed head's,
#       in the page's own words (the words of the desk), the organisation once,
#       and the page head keeps its tools. Inside a project the fixed head keeps
#       the project and the area tabs; an area's head drops its title and the
#       project, a page below an area keeps its own title.
#       MobileNavigationHelper#mobile_head_echo decides, components/mobile_app.css hides.
# Why:  until 2026-11-24 the page head stood under the fixed head on nearly
#       every page: "Zeiten" and the organisation twice, "Start" over
#       "Übersicht", "Verwaltung" over "Allgemein" (user: "sehr verwirrend").
#       The five pages without it had each dropped it in a way of their own.
#       Only a browser shows what is visible, so this guard visits the pages.
RSpec.describe 'The page head on a phone', type: :system do
  let(:organisation) { create(:organisation, name: 'Beispiel GmbH', ai_enabled: true) }
  let(:admin) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Leuchtturm') } }

  before do
    Prosopite.pause
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation,
                          role: create(:admin_role, organisation: organisation), active: true)
    end
    sign_in admin
    page.driver.browser.execute_cdp('Emulation.setDeviceMetricsOverride', width: 390, height: 844,
                                                                          deviceScaleFactor: 1, mobile: true)
  end

  # The browser outlives the example: without this every later spec runs on a phone.
  after do
    page.driver.browser.execute_cdp('Emulation.clearDeviceMetricsOverride')
    page.driver.browser.execute_cdp('Emulation.setTouchEmulationEnabled', enabled: false)
    Prosopite.resume
  end

  # Every heading the reader sees, the fixed head's included.
  def visible_headings = all('h1').map { |node| node.text.squish }

  def fixed_head_lines = [find('.mobile-heading h1').text.squish, find('.mobile-heading p').text.squish]

  # The links and buttons of the page head that the reader still sees: its row
  # is three levels above its title (title line, title column, row).
  def page_head_tools
    row = find('main h1', match: :first, visible: :all).find(:xpath, '../../..', visible: :all)
    row.all('a, button, summary', visible: true)
  end

  # The page head's second line where it names the organisation or the project.
  def page_head_line(text) = all('main p.text-muted.truncate', exact_text: text)

  it 'names each page of the organisation once, in its own words, and keeps its tools' do
    pages = {
      organisation_root_path(organisation) => I18n.t('dashboard.briefing.global_overview_title'),
      organisation_notifications_path(organisation) => nil,
      organisation_time_sessions_path(organisation) => nil,
      organisation_time_session_groups_path(organisation) => nil,
      organisation_settings_path(organisation) => I18n.t('settings.organisation_settings'),
      organisation_memberships_path(organisation) => I18n.t('settings.members'),
      organisation_ai_overview_path(organisation) => I18n.t('settings.ai'),
      organisation_meetings_path(organisation, viewport: 'mobile') => nil,
      organisation_glossary_terms_path(organisation, viewport: 'mobile') => nil,
      organisation_people_path(organisation, viewport: 'mobile') => nil
    }

    pages.each do |path, pinned|
      visit path
      expect(page).to have_css('.mobile-heading h1')
      title = find('main h1', match: :first, visible: :all).text(:all).squish
      expect(title).to eq(pinned) if pinned

      expect(visible_headings).to eq([title]), "#{path}: #{visible_headings.inspect}"
      expect(fixed_head_lines).to eq([title, 'Beispiel GmbH']), path
      expect(page_head_line('Beispiel GmbH')).to be_empty, path
      expect(page_head_tools).not_to be_empty, path
    end
  end

  it 'takes a head with nothing but the name away as a whole' do
    { organisation_mobile_projects_path(organisation) => I18n.t('mobile.projects'),
      organisation_mobile_more_path(organisation) => I18n.t('mobile.more') }.each do |path, title|
      visit path

      expect(page).to have_css('.mobile-heading h1', exact_text: title)
      expect(visible_headings).to eq([title])
      head = find('main h1', exact_text: title, visible: :all).find(:xpath, '../../../..', visible: :all)
      expect(head).not_to be_visible
      expect(head.evaluate_script('this.getBoundingClientRect().height')).to eq(0)
    end
  end

  it 'calls the start page "Übersicht" in the fixed head, the bottom bar and the desk\'s sidebar' do
    visit organisation_root_path(organisation)

    overview = I18n.t('dashboard.briefing.global_overview_title')
    expect(page).to have_css('.mobile-heading h1', exact_text: overview)
    expect(page).to have_css('.mobile-bottom-links .is-active', text: overview)
    expect(I18n.t('navigation.org_dashboard')).to eq(overview)
    expect(I18n.t('mobile.start')).to eq(overview)
  end

  it 'keeps the project and its tabs in the fixed head, and an area\'s head drops what they say' do
    pages = [
      organisation_project_path(organisation, project),
      organisation_project_knowledge_index_path(organisation, project, viewport: 'mobile'),
      organisation_project_meetings_path(organisation, project, viewport: 'mobile'),
      organisation_project_project_permissions_path(organisation, project),
      edit_organisation_project_path(organisation, project),
      organisation_project_activities_path(organisation, project)
    ]

    pages.each do |path|
      visit path
      expect(page).to have_css('.mobile-heading h1', text: 'Leuchtturm')

      expect(visible_headings).to eq(['Leuchtturm']), "#{path}: #{visible_headings.inspect}"
      expect(fixed_head_lines).to eq(['Leuchtturm', 'Beispiel GmbH']), path
      expect(page).to have_css('.mobile-project-tabs [aria-current="page"]'), path
      expect(page_head_line('Leuchtturm')).to be_empty, path
    end
  end

  it 'keeps the title of a page below an area, which the tabs do not name' do
    visit organisation_project_ticket_attribute_definitions_path(organisation, project)

    title = I18n.t('views.organisations.ticket_attribute_definitions.index.title')
    expect(page).to have_css('main h1', exact_text: title)
    expect(visible_headings).to eq(['Leuchtturm', title])
    expect(page_head_line('Leuchtturm')).to be_empty
  end
end
