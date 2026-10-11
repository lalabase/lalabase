# frozen_string_literal: true

require 'rails_helper'

# What: The times area (the one time list and the billings behind it) has a
#       tab bar "Zeiten | Abrechnungen" under each page's title box, instead of
#       a header button on each list pointing at the other. Same pattern as the
#       management area (shared/_settings_subnav): the tabs and the sidebar
#       highlight derive from ONE list, NavigationHelper::TIMES_TABS.
# Type: Request spec over the rendered pages.
# Why:  A tab the reader may not open is not shown (a tab that ends in an error
#       message is a promise without cover); with one tab left there is no bar.
#       The sidebar entry "Zeiten" stays lit on the billing pages, so the
#       area does not go dark while the reader is in the middle of it.
RSpec.describe 'Times area subnav', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role)   { create(:admin_role, organisation: organisation) }
  let(:finance_role) { create(:role, organisation: organisation, title: 'Buchhaltung') }
  let(:member_role)  { create(:role, organisation: organisation) }
  let(:project)      { with_tenant { create(:project, organisation: organisation) } }
  let(:nav_label)    { I18n.t('navigation.times_tabs.label') }

  before do
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  def with_tenant(&block)
    ActsAsTenant.with_tenant(organisation, &block)
  end

  def join(user, role)
    with_tenant { create(:membership, user: user, organisation: organisation, role: role, active: true) }
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  def subnav
    doc.css("nav[aria-label='#{nav_label}']").first
  end

  def tab_links
    subnav.css('a').map { |a| [a['href'], a['aria-current']] }
  end

  # Links outside the sidebar: the sidebar entry "Zeiten" points at the time
  # list too, and it is not the header button this spec says is gone.
  def page_links_to(path)
    doc.css("a[href='#{path}']").reject { |a| a.ancestors('#sidebar').any? }
  end

  def times_path
    organisation_time_sessions_path(organisation)
  end

  def billings_path
    organisation_time_session_groups_path(organisation)
  end

  context 'as account admin' do
    let(:admin) { create(:user) }

    before do
      join(admin, admin_role)
      sign_in admin
    end

    it 'shows the bar on the time list with "Zeiten" active and no header button to the billings' do
      get times_path

      expect(response).to have_http_status(:ok)
      expect(subnav).to be_present, 'no times subnav on the time list'
      expect(tab_links).to contain_exactly([times_path, 'page'], [billings_path, nil])
      # The tab is the ONE way over: the old header button is gone.
      expect(page_links_to(billings_path).size).to eq(1)
    end

    it 'shows the bar on the billing list with "Abrechnungen" active and no header button to the times' do
      get billings_path

      expect(response).to have_http_status(:ok)
      expect(subnav).to be_present, 'no times subnav on the billing list'
      expect(tab_links).to contain_exactly([times_path, nil], [billings_path, 'page'])
      expect(page_links_to(times_path).size).to eq(1)
    end

    it 'shows the bar on a billing detail page and on the new-billing page, "Abrechnungen" active' do
      group = with_tenant { create(:time_session_group, organisation: organisation, creator: admin) }

      get chronological_organisation_time_session_group_path(organisation, group)
      expect(response).to have_http_status(:ok)
      expect(tab_links).to include([billings_path, 'page'], [times_path, nil])
      # The way back to the list stays: a detail page needs it, the tab is not "back".
      expect(response.body).to include(I18n.t('views.organisations.time_session_groups.show_header.back_to_list'))

      get new_organisation_time_session_group_path(organisation)
      expect(response).to have_http_status(:ok)
      expect(tab_links).to include([billings_path, 'page'], [times_path, nil])
    end

    # The sidebar highlight derives from the same list as the tabs: "Zeiten"
    # stays lit on every page of the area, not only on the time list.
    it 'keeps the sidebar entry "Zeiten" lit on the billing pages' do
      get billings_path

      sidebar_link = doc.css("a[href='#{times_path}']").find { |a| a.text.include?(I18n.t('navigation.times')) }
      expect(sidebar_link).to be_present, 'no "Zeiten" sidebar entry'
      # The one marker of an active sidebar row since 07.09.2026 (SidebarNavHelper).
      # It used to be the ink bar on the left; that went when the shell got
      # darker and the state became a raised tile instead of a tint.
      expect(sidebar_link['class']).to include('sidebar-row--active')
    end

    # The entry used to read "Alle Zeiten" to set it apart from a project's own
    # "Projektzeiten". That page is gone (#675), so the "Alle" says nothing any
    # more (user, 01.09.2026).
    it 'names the sidebar entry "Zeiten", not "Zeiten"' do
      get times_path

      sidebar_link = doc.css("#sidebar a[href='#{times_path}']").first
      expect(sidebar_link).to be_present
      expect(sidebar_link.text.strip).to eq('Zeiten')
      expect(response.body).not_to include('Alle Zeiten')
    end

    # The filter header used to carry its own tab switcher ("Filter" and the
    # status table); the table is a VIEW of the page now, switched top right
    # (time_sessions_overview_view_spec), and the in-page tabs are gone.
    it 'has no in-page tab switcher any more' do
      with_tenant { create(:time_session, organisation: organisation, project: project, creator: admin) }

      get times_path

      expect(response.body).not_to include('data-tab-id=')
      expect(response.body).not_to include('Übersicht Abrechnungen')
      expect(response.body).to include(I18n.t('views.organisations.time_sessions.index.view_overview'))
    end
  end

  context 'as a member with a finance role (billings, no admin)' do
    let(:bookkeeper) { create(:user) }

    before do
      join(bookkeeper, finance_role)
      with_tenant { create(:time_session_permission, user: bookkeeper, project: project, can_view_own: true) }
      sign_in bookkeeper
    end

    it 'gets both tabs' do
      get times_path

      expect(response).to have_http_status(:ok)
      expect(tab_links).to contain_exactly([times_path, 'page'], [billings_path, nil])
    end
  end

  context 'as a member who sees time but may not open the billings' do
    let(:viewer) { create(:user) }

    before do
      join(viewer, member_role)
      with_tenant { create(:time_session_permission, user: viewer, project: project, can_view_own: true) }
      sign_in viewer
    end

    it 'gets no bar at all: one tab is nothing to switch, and the billings are not offered' do
      get times_path

      expect(response).to have_http_status(:ok)
      expect(subnav).to be_nil
      expect(doc.css("a[href='#{billings_path}']")).to be_empty
    end
  end
end
