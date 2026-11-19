# frozen_string_literal: true

require 'rails_helper'

# What: the globe at the end of the sidebar's "Inbox" and "Personen" rows, a link to
#       the same page above the organisations (GET /inbox, GET /people).
# Why:  a person with two or more organisations reaches those pages from inside an
#       organisation without the switcher. The globe follows the rule of the other
#       ways there (level_home_path, the phone's "Mehr" page): two or more active
#       organisations, nobody else. It is a link BESIDE the row's link, never inside
#       it, so the row keeps leading to the organisation's own page. How it shows
#       (hidden, faint, on its tile) is the browser's: spec/system/sidebar_across_organisations_spec.rb.
RSpec.describe 'Globe to the pages above the organisations in the sidebar', :real_transactions, type: :request do
  let(:user) { create(:user) }
  let(:north) { create(:organisation, name: 'Nordwind GmbH') }
  let(:south) { create(:organisation, name: 'Suedhang AG') }

  def join(org, active: true)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org, role: create(:admin_role, organisation: org), active: active)
    end
  end

  # The inbox answers a bare address with a redirect to its default filters.
  def inbox_page
    organisation_notifications_path(north, state_filters: %w[read unread])
  end

  def sidebar_of(path)
    get path
    expect(response).to have_http_status(:ok), response.location.to_s
    nav_row = Nokogiri::HTML5(response.body).at_css("a.sidebar-row[href='#{organisation_people_path(north)}']")
    expect(nav_row).to be_present # the page rendered its sidebar with the people row
    nav_row.ancestors('ul').first
  end

  def row_item(sidebar, path)
    sidebar.at_css("a.sidebar-row[href='#{path}']").parent
  end

  before do
    join(north)
    sign_in user
    Prosopite.pause # the pages below have known N+1 in their own render paths
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  context 'with two organisations' do
    before { join(south) }

    it 'puts a globe to /inbox beside the inbox row and one to /people beside the people row' do
      sidebar = sidebar_of(inbox_page)

      inbox = row_item(sidebar, organisation_notifications_path(north))
      globe = inbox.at_css('a[data-sidebar-across]')
      expect(globe['href']).to eq(all_inboxes_path)
      expect(globe['aria-label']).to eq(I18n.t('navigation.across_organisations.inbox'))
      expect(globe['data-turbo-frame']).to eq('_top')
      expect(globe.at_css('i.bi.bi-globe2[aria-hidden="true"]')).to be_present

      people = row_item(sidebar, organisation_people_path(north))
      globe = people.at_css('a[data-sidebar-across]')
      expect(globe['href']).to eq(all_people_path)
      expect(globe['aria-label']).to eq(I18n.t('navigation.across_organisations.people'))

      expect(sidebar.css('a[data-sidebar-across]').size).to eq(2)
    end

    it 'keeps the globe out of the row link, so the row still leads to the organisation' do
      sidebar = sidebar_of(organisation_people_path(north))

      [organisation_notifications_path(north), organisation_people_path(north)].each do |path|
        row = sidebar.at_css("a.sidebar-row[href='#{path}']")
        expect(row.at_css('a')).to be_nil
        expect(row.parent['class'].split).to include('sidebar-item--across')
      end
    end

    it 'names the globe in English on an English page' do
      user.update!(language_preference: 'en')
      sidebar = sidebar_of(inbox_page)

      labels = sidebar.css('a[data-sidebar-across]').map { |link| link['aria-label'] }
      expect(labels).to contain_exactly('Inbox of all organisations', 'People of all organisations')
    end

    it 'leads to the pages above the organisations' do
      sidebar = sidebar_of(inbox_page)

      get sidebar.at_css("a[data-sidebar-across][href='#{all_inboxes_path}']")['href']
      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML5(response.body).at_css('[data-all-inboxes]')).to be_present

      get sidebar.at_css("a[data-sidebar-across][href='#{all_people_path}']")['href']
      expect(response).to have_http_status(:ok)
    end
  end

  context 'with one organisation' do
    it 'shows no globe' do
      sidebar = sidebar_of(inbox_page)

      expect(row_item(sidebar, organisation_notifications_path(north))).to be_present
      expect(sidebar.css('a[data-sidebar-across]')).to be_empty
      expect(sidebar.css('.sidebar-item--across')).to be_empty
    end
  end

  context 'with a second membership that is deactivated' do
    before { join(south, active: false) }

    it 'shows no globe' do
      sidebar = sidebar_of(inbox_page)

      expect(sidebar.css('a[data-sidebar-across]')).to be_empty
    end
  end
end
