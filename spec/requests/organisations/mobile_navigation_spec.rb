# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Mobile application navigation', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, title: 'Ein langer Titel, der vollständig auf dem Telefon lesbar bleibt') }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    sign_in user
    ticket
  end
  after { ActsAsTenant.current_tenant = nil }

  def html
    Nokogiri::HTML(response.body)
  end

  it 'labels the members page in German on phones' do
    get organisation_memberships_path(organisation), params: { viewport: 'mobile' }
    expect(response).to have_http_status(:ok)
    expect(html.at_css('.mobile-heading h1').text.strip).to eq('Mitglieder')
  end

  it 'labels the organisation meeting overview in German on phones' do
    get organisation_meetings_path(organisation), params: { viewport: 'mobile' }
    expect(response).to have_http_status(:ok)
    expect(html.at_css('.mobile-heading h1').text.strip).to eq('Alle Meetings')
  end

  it 'renders a real mobile list with a creation action and two navigation levels' do
    get organisation_project_tickets_path(organisation, project), params: { viewport: 'mobile' }
    expect(response).to have_http_status(:ok)
    expect(html.at_css('#tickets_list_frame table')).to be_nil
    expect(html.at_css('.mobile-ticket-title').text).to eq(ticket.title)
    expect(html.at_css('.mobile-header a[data-turbo-frame="writing_surface"]')).to be_present
    expect(html.css('.mobile-bottom-links a').map(&:text).join).to include('Start', 'Inbox', 'Projekte', 'Zeiten', 'Mehr')
    expect(html.at_css('.mobile-bottom-links .is-active')['href']).to eq(organisation_mobile_projects_path(organisation))
    expect(html.at_css('.mobile-project-tabs [aria-current]').text).to include('Tickets')
  end

  it 'answers search frame requests with mobile rows and the canonical frame' do
    get organisation_project_tickets_path(organisation, project), params: { viewport: 'mobile', search: 'Telefon' }, headers: { 'Turbo-Frame' => 'tickets_list_frame' }
    expect(response).to have_http_status(:ok)
    expect(html.at_css('turbo-frame#tickets_list_frame .mobile-ticket-title')).to be_present
    expect(html.at_css('table')).to be_nil
  end

  it 'offers a project destination instead of redirecting to the dashboard' do
    get organisation_mobile_projects_path(organisation)
    expect(response).to have_http_status(:ok)
    expect(html.at_css('.mobile-project-list').text).to include(project.name)
  end

  it 'renders More with organisation and personal destinations' do
    get organisation_mobile_more_path(organisation)
    expect(response).to have_http_status(:ok)
    expect(html.at_css('.mobile-person').text).to include(organisation.name)
    expect(html.css('.mobile-menu-list a').map { |a| a['href'] }).to include(edit_user_registration_path, general_user_preferences_path, user_data_export_path, organisation_changelog_path(organisation))
    expect(html.css('[data-theme-set]').map { |button| button['data-theme-set'] }).to include('light', 'dark', 'pop')
    expect(html.at_css('[data-action="personal-tasks-drawer#open"]')).to be_present
  end

  it 'keeps the table response on desktop' do
    get organisation_project_tickets_path(organisation, project)
    expect(response).to have_http_status(:ok)
    expect(html.at_css('#tickets_list_frame table')).to be_present
    expect(html.at_css('.mobile-ticket-row')).to be_nil
  end
  it 'returns mobile row markup after editing and removes mobile rows after deleting' do
    patch organisation_project_ticket_path(organisation, project, ticket), params: { viewport: 'mobile', ticket: { title: 'Geändert' } }, headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' }
    expect(response).to have_http_status(:ok)
    stream = html.at_css('turbo-stream[action="replace"] template .mobile-ticket-row')
    expect(stream).to be_present
    expect(stream.at_css('.mobile-ticket-title').text).to eq('Geändert')
    delete organisation_project_ticket_path(organisation, project, ticket), params: { viewport: 'mobile' }, headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' }
    expect(response).to have_http_status(:ok)
    expect(html.at_css('turbo-stream[action="remove"]')['targets']).to include('.mobile-ticket-row')
  end

  it 'omits other organisations from project links and counts' do
    other_org = create(:organisation)
    other_project = ActsAsTenant.with_tenant(other_org) { create(:project, organisation: other_org, name: 'Fremdes Projekt') }
    get organisation_mobile_projects_path(organisation)
    expect(response).to have_http_status(:ok)
    expect(html.at_css('.mobile-project-list').text).not_to include(other_project.name)
  end

  it 'gives readers the list without selection and creation controls' do
    membership = user.memberships.find_by!(organisation: organisation)
    membership.update!(role: create(:role, organisation: organisation))
    create(:project_permission, user: user, project: project, tickets_access: 'read_only')
    get organisation_project_tickets_path(organisation, project), params: { viewport: 'mobile' }
    expect(response).to have_http_status(:ok)
    expect(html.at_css('.mobile-ticket-title')).to be_present
    expect(html.at_css('.mobile-header a[data-turbo-frame="writing_surface"]')).to be_nil
    expect(html.at_css('.mobile-ticket-check')).to be_nil
  end
  it 'explains an empty project list and omits empty organisation menu groups' do
    user.memberships.find_by!(organisation: organisation).update!(role: create(:role, organisation: organisation))
    get organisation_mobile_projects_path(organisation)
    expect(response).to have_http_status(:ok)
    expect(html.css('.mobile-project-list a')).to be_empty
    expect(html.at_css('[data-mobile-project-search-target="empty"]')['hidden']).to be_nil
    get organisation_mobile_more_path(organisation)
    expect(response).to have_http_status(:ok)
    expect(html.css('.mobile-destination h2').map(&:text)).to eq([I18n.t('mobile.me')])
  end
  it 'shows project time navigation only with a persisted viewing permission' do
    user.memberships.find_by!(organisation: organisation).update!(role: create(:role, organisation: organisation))
    create(:project_permission, user: user, project: project, tickets_access: 'read_only')
    get organisation_project_tickets_path(organisation, project), params: { viewport: 'mobile' }
    expect(html.css('.mobile-project-tabs a').map(&:text)).not_to include(I18n.t('mobile.times'))
    expect(html.at_css('.mobile-ticket-time')).to be_nil

    create(:time_session_permission, user: user, project: project, can_view_own: true)
    get organisation_project_tickets_path(organisation, project), params: { viewport: 'mobile' }
    expect(html.css('.mobile-project-tabs a').map(&:text)).to include(I18n.t('mobile.times'))
    expect(html.at_css('.mobile-ticket-time')).to be_present
  end
  it 'opens the created ticket when creation starts from standalone mobile detail' do
    get organisation_project_ticket_path(organisation, project, ticket), params: { viewport: 'mobile' }
    expect(html.at_css('.mobile-header a[data-turbo-frame="writing_surface"]')['href']).to include('source=mobile_detail')
    post organisation_project_tickets_path(organisation, project),
         params: { viewport: 'mobile', source: 'mobile_detail', ticket: { title: 'Created from detail' } },
         headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' }
    expect(response).to have_http_status(:ok)
    created = ActsAsTenant.with_tenant(organisation) { project.tickets.find_by!(title: 'Created from detail') }
    expect(response.body).to include(organisation_project_ticket_path(organisation, project, created, viewport: 'mobile'))
    expect(response.body).not_to include('action="reloadFrame"')
  end
  it 'uses the viewport header for tickets, while Meetings keeps its own boundary' do
    get organisation_project_tickets_path(organisation, project), headers: { 'X-Viewport' => 'mobile' }
    expect(html.at_css('#tickets_list_frame .mobile-ticket-row')).to be_present
    get organisation_project_meetings_path(organisation, project), headers: { 'X-Viewport' => 'mobile' }
    expect(html.at_css('[data-viewport-current-mode-value]')['data-viewport-current-mode-value']).to eq('desktop')
  end

  it 'keeps the saved Kanban preference while rendering a mobile list' do
    configuration = ViewConfiguration.for_user_project(user, project)
    configuration.update!(view_mode: 'kanban')
    get organisation_project_tickets_path(organisation, project), headers: { 'X-Viewport' => 'mobile' }
    expect(html.at_css('.mobile-ticket-row')).to be_present
    expect(ActsAsTenant.with_tenant(organisation) { configuration.reload.view_mode }).to eq('kanban')
  end

  it 'does not expose an unreadable project through project_context' do
    user.memberships.find_by!(organisation: organisation).update!(role: create(:role, organisation: organisation))
    create(:project_permission, user: user, project: project, tickets_access: 'read_only')
    hidden_project = create(:project, organisation: organisation, name: 'Nicht freigegeben')
    get organisation_mobile_projects_path(organisation), params: { project_context: hidden_project.id }
    expect(response).to have_http_status(:ok)
    expect(html.at_css('.mobile-heading').text).not_to include(hidden_project.name)
    expect(html.at_css('.mobile-project-list').text).not_to include(hidden_project.name)
  end

  it 'defers the project switcher and its ticket counts for a non-admin with several projects' do
    user.memberships.find_by!(organisation: organisation).update!(role: create(:role, organisation: organisation))
    create(:project_permission, user: user, project: project, tickets_access: 'read_only')
    8.times do
      another = create(:project, organisation: organisation)
      create(:project_permission, user: user, project: another, tickets_access: 'read_only')
    end
    count_queries = []
    subscriber = lambda do |*args|
      sql = args.last[:sql]
      count_queries << sql if sql.match?(/COUNT.*tickets.*GROUP BY.*project_id/i)
    end
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
      get organisation_project_tickets_path(organisation, project)
    end
    expect(count_queries).to be_empty
    expect(html.at_css('.mobile-page-head .mobile-project-list')).to be_nil
    frame = html.at_css('turbo-frame#mobile_project_switcher')
    expect(frame['loading']).to eq('lazy')
    get frame['src'], headers: { 'Turbo-Frame' => 'mobile_project_switcher' }
    expect(response).to have_http_status(:ok)
    expect(html.css('#mobile_project_switcher .mobile-project-list a').size).to eq(9)
    expect(html.at_css('#mobile_project_switcher input[type="search"]')).to be_present
  end

  it 'keeps mobile page two while retaining the existing desktop page-one redirect' do
    create(:ticket, project: project, title: 'Ein zweiter Titel')
    get organisation_project_tickets_path(organisation, project), params: { viewport: 'mobile', page: 2, items: 1, search: 'Titel', search_mode: 'title_only' }
    expect(response).to have_http_status(:ok)
    expect(html.at_css('.mobile-pagination').text).to include('2 / 2')
    get organisation_project_tickets_path(organisation, project), params: { viewport: 'desktop', page: 2, items: 1, search: 'Titel', search_mode: 'title_only' }
    expect(response).to have_http_status(:redirect)
    query = Rack::Utils.parse_nested_query(URI.parse(response.location).query)
    expect(query).to include('search' => 'Titel', 'items' => '1')
    expect(query).not_to have_key('page')
  end
end
