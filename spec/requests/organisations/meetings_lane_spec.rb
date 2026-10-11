# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Meetings detail lane', type: :request do
  let(:organisation) { create(:organisation, ai_enabled: true) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end
  let(:meeting) do
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting,
             organisation: organisation,
             project: project,
             creator: user,
             title: "Strategische Abstimmung #{'international ' * 8}",
             notes: 'Nur die Notizen',
             transcript: "Anna: Eins\nGuido: Zwei")
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation,
                        role: create(:admin_role, organisation: organisation), active: true)
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def page = Capybara.string(response.body)
  def meetings_path(**params) = organisation_project_meetings_path(organisation, project, **params)

  it 'puts the page head inside a resizable meeting-specific lane grid' do
    meeting
    get meetings_path

    grid = 'div.layout.two-column.layout--lane[data-controller="lane-split"]'
    expect(response).to have_http_status(:ok)
    expect(page).to have_css(grid)
    expect(page).to have_css("#{grid}[data-lane-split-storage-key-value='meetings']")
    expect(page).to have_css("#{grid}[data-index-page-target='layout']")
    expect(page).to have_css("#{grid} aside.column.list", text: I18n.t('views.organisations.meetings.index.title'))
    expect(page).to have_css("#{grid} .lane-split[role='separator']")
    expect(page).to have_no_css('aside.column.panel', visible: :all)
  end

  it 'keeps list filtering inside its frame instead of promoting it to a full visit' do
    meeting
    get meetings_path(search: 'Strategische'), headers: { 'Turbo-Frame' => 'meetings_results' }

    expect(response).to have_http_status(:ok)
    expect(page).to have_css("turbo-frame#meetings_results[data-keyboard-navigation-target='listContainer']")
    query = Rack::Utils.parse_nested_query(page.find('#meetings_results [data-list-filter-query]')['data-list-filter-query'])
    expect(query).to include('search' => 'Strategische')
    expect(page).not_to have_css('[data-layout-toggle-list-filter-params-value]')
    expect(response.body).not_to include('turbo-visit-control')
  end

  it 'wires every meeting row to the shared address and history owner' do
    get meetings_path(meeting_id: meeting.id, search: 'Strategische')

    row = page.find("tr[data-meeting-id='#{meeting.id}']")
    expect(row['data-controller']).to eq('list-row')
    expect(row['data-list-row-param-value']).to eq('meeting_id')
    expect(row['data-list-row-frame-value']).to eq('meeting_display_frame')
    expect(row['data-list-row-url-value']).to eq(organisation_project_meeting_path(organisation, project, meeting))
    expect(row[:class].split).to include('selected-row')
    expect(page).to have_css("[data-index-url='#{meetings_path}']")
  end

  it 'renders the quiet common header hierarchy without the former detail card' do
    get meetings_path(meeting_id: meeting.id)

    root = page.find('#meeting-header')
    expect(root[:class].split).to include('meeting-content')
    expect(root[:class]).not_to match(/bg-cream|rounded|border-cream/)
    expect(root).to have_css('[data-lane-head]', text: I18n.t('views.organisations.meetings.show.type_label'))
    expect(root).to have_css("[data-lane-close][title='#{I18n.t('views.organisations.meetings.show.close')}']", visible: :all)
    expect(root).to have_css('h2.break-words', text: 'Strategische Abstimmung')
    expect(root).to have_css('.width-text', text: 'Nur die Notizen')
    expect(page).to have_css("#analyses_meeting_#{meeting.id}")
    expect(page).to have_css("#ticket_suggestions_meeting_#{meeting.id}")
    expect(page).to have_css("#ticket_links_meeting_#{meeting.id}")
  end

  it 'keeps search, participant and viewport on the mobile way back and edit action' do
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting_participant, meeting: meeting, organisation: organisation, display_name: 'Anna Beispiel')
    end
    get meetings_path(meeting_id: meeting.id, search: 'Strategische', participant: 'anna beispiel', viewport: 'mobile')

    back = page.find('.mobile-detail-view a', text: I18n.t('views.organisations.meetings.index.mobile_list_view'))
    back_uri = URI.parse(back[:href])
    back_params = Rack::Utils.parse_nested_query(back_uri.query)
    expect(back_params).to include('search' => 'Strategische', 'participant' => 'anna beispiel', 'viewport' => 'mobile')
    expect(back_params).not_to have_key('meeting_id')

    edit = page.find("a[title='#{I18n.t('views.organisations.meetings.show.edit_meeting')}']")
    expect(edit[:href]).to include('search=Strategische', 'participant=anna+beispiel', 'viewport=mobile')
  end

  it 'renders the new form as the single mobile detail after the frame fallback redirect' do
    get new_organisation_project_meeting_path(organisation, project,
                                              frame: 'content', frame_id: 'meeting_display_frame',
                                              search: 'alpha', viewport: 'mobile')

    expect(response).to redirect_to(meetings_path(new: 'meeting', search: 'alpha', viewport: 'mobile'))
    follow_redirect!
    expect(page).to have_css('.mobile-detail-view #meeting-form-card.meeting-content')
    expect(page).to have_css('.mobile-detail-view', text: I18n.t('views.organisations.meetings.index.mobile_list_view'), count: 1)
    expect(page).to have_no_css('.mobile-list-view', visible: :all)
  end

  it 'closes a desktop new form through a filter-preserving URL without form state' do
    get meetings_path(new: 'meeting', search: 'alpha', participant: 'anna', viewport: 'desktop')

    ['[data-lane-close]', '[data-form-lane-back]'].each do |selector|
      close = page.find("#meeting-form-card #{selector}", visible: :all)
      uri = URI.parse(close[:href])
      query = Rack::Utils.parse_nested_query(uri.query)
      expect(query).to eq('search' => 'alpha', 'participant' => 'anna', 'viewport' => 'desktop')
    end
  end

  it 'keeps contextual help and time capture reachable in the mobile detail' do
    get meetings_path(meeting_id: meeting.id, viewport: 'mobile')

    expect(page).to have_css('.mobile-detail-view [data-lane-head] [data-controller="dropdown"]')
    expect(page).to have_css('.mobile-detail-view [data-controller="neo-inline-popover"]')
  end

  it 'keeps edit and cancel in the same filtered detail frame' do
    get edit_organisation_project_meeting_path(organisation, project, meeting,
                                               format: :turbo_stream,
                                               frame_id: 'meeting_display_frame',
                                               search: 'Strategische', participant: 'anna', viewport: 'desktop'),
        headers: { 'Turbo-Frame' => 'meeting_display_frame' }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('meeting-content', 'meeting_display_frame', 'search=Strategische', 'participant=anna')
    expect(response.body).not_to include('bg-cream-50 py-6 px-8 rounded-lg border')
  end
end
