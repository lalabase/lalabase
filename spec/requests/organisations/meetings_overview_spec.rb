# frozen_string_literal: true

require 'rails_helper'

# "Alle Meetings" (/organisations/:id/meetings): the organisation-wide meetings
# list. Since 17.10.2026 it is the same list as the project meetings page
# (doc/meetings_uebersicht_vereinheitlichen_plan.md, PR 1): the shared filter bar
# with saved views, "+ Filter" and the search with its depth, sort by column
# head, pagination. Two things exist only here: the filter category "Projekt"
# and the column "Projekt". What the page may reveal is pinned by
# meetings_overview_access_spec.rb; this file is about behaviour.
RSpec.describe 'Organisations::MeetingsOverview', type: :request do
  let(:organisation) { create(:organisation) }
  let(:project_a) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Alpha') } }
  let(:project_b) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Beta') } }
  let(:overview_path) { organisation_meetings_path(organisation) }

  # `on:` accepts a single project or an array; :none grants membership only.
  def user_with_access(level, on: project_a)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      Array(on).each { |proj| create(:project_permission, user: user, project: proj, meetings_access: level) } unless level == :none
    end
    user
  end

  let(:reader) { user_with_access('read_only', on: [project_a, project_b]) }

  # Setup writes re-read the tenant organisation per participant; that is setup
  # noise, not the request under test, so Prosopite does not scan it.
  def create_meeting(project:, title:, participants: [], creator: reader, **attributes)
    Prosopite.pause { create_meeting!(project: project, title: title, participants: participants, creator: creator, **attributes) }
  end

  def create_meeting!(project:, title:, participants:, creator:, **attributes)
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting, project: project, organisation: organisation, creator: creator, title: title, **attributes).tap do |meeting|
        participants.each { |name| create(:meeting_participant, meeting: meeting, display_name: name) }
      end
    end
  end

  def page_body
    Capybara.string(response.body)
  end

  def list(**params)
    get overview_path, params: params
    expect(response).to have_http_status(:ok)
    page_body
  end

  def titles(page = page_body)
    page.all('#meetings_overview_results tr[data-meeting-id] h5').map { |title| title.text.strip }
  end

  describe 'access gate' do
    it 'renders for a user with meetings read access in at least one project' do
      sign_in user_with_access('read_only')
      get overview_path
      expect(response).to have_http_status(:ok)
    end

    it 'redirects a user with no meetings access in any project' do
      sign_in user_with_access(:none)
      get overview_path
      expect(response).to have_http_status(:redirect)
    end

    it 'redirects an unauthenticated user to login' do
      get overview_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe 'the list head' do
    before { sign_in reader }

    it 'shows the shared filter bar: base tab, "+ Filter" and the search with its depth' do
      create_meeting(project: project_a, title: 'Alpha Kickoff')
      page = list

      bar = page.find('[data-controller="filter-bar"]')
      expect(bar['data-filter-bar-frame-value']).to eq('meetings_overview_results')
      expect(bar['data-filter-bar-url-value']).to eq(overview_path)
      expect(bar['data-filter-bar-project-id-value']).to be_blank
      expect(page).to have_css('[role="tab"]', text: I18n.t('smart_folders.all_meetings'))
      expect(page).to have_css('[data-filter-bar-target="searchInput"]')
      expect(bar.all('button[data-mode]', visible: :all).map { |mode| mode['data-mode'] }).to contain_exactly('title_only', 'content')
      keys = JSON.parse(bar['data-filter-bar-categories-value']).map { |category| category['key'] }
      expect(keys).to eq(%w[project participant creator occurred_at created_at updated_at])
    end

    it 'no longer renders its own search field and the two selects' do
      create_meeting(project: project_a, title: 'Alpha Kickoff')
      page = list

      content = page.find('[data-controller~="index-page"]')
      expect(content).to have_css('[data-controller="filter-bar"]')
      expect(page).not_to have_css('#meetings-overview-filters')
      expect(content).not_to have_css('select[name="participant"], select[name="project_id"]')
    end

    it 'saves a new view without a project and back to this page' do
      create_meeting(project: project_a, title: 'Alpha Kickoff')
      page = list
      bar = page.find('[data-controller="filter-bar"]')
      save_url = bar['data-filter-bar-save-url-value']

      expect(save_url).to include('target_object_type=Meeting')
      expect(bar.find_link(I18n.t('components.filter_bar.open_expert_filter'), visible: :all)[:href]).not_to include('project_id')
    end
  end

  describe 'filters' do
    before { sign_in reader }

    let!(:alpha) { create_meeting(project: project_a, title: 'Alpha Kickoff', participants: ['Anna Müller', 'Clara Klein'], occurred_at: 2.days.ago) }
    let!(:beta) { create_meeting(project: project_b, title: 'Beta Retro', participants: ['Anna Müller'], occurred_at: 1.day.ago) }
    let!(:gamma) { create_meeting(project: project_a, title: 'Gamma Sync', participants: ['Bert Berg'], occurred_at: 3.days.ago) }
    let(:anna) { MeetingParticipant.normalize_name('Anna Müller') }
    let(:clara) { MeetingParticipant.normalize_name('Clara Klein') }

    it 'filters by project, and excludes a project with "not"' do
      expect(titles(list(filter: { project: [project_a.id] }))).to eq(['Alpha Kickoff', 'Gamma Sync'])
      expect(titles(list(filter: { project: [project_a.id] }, filter_op: { project: 'not' }))).to eq(['Beta Retro'])
      expect(titles(list(filter: { project: [project_a.id, project_b.id] }))).to eq(['Beta Retro', 'Alpha Kickoff', 'Gamma Sync'])
    end

    it 'filters by participant with or, and, not' do
      expect(titles(list(filter: { participant: [anna] }))).to eq(['Beta Retro', 'Alpha Kickoff'])
      expect(titles(list(filter: { participant: [anna, clara] }, filter_op: { participant: 'and' }))).to eq(['Alpha Kickoff'])
      expect(titles(list(filter: { participant: [anna] }, filter_op: { participant: 'not' }))).to eq(['Gamma Sync'])
    end

    it 'combines project, participant and the search' do
      expect(titles(list(filter: { project: [project_a.id], participant: [anna] }))).to eq(['Alpha Kickoff'])
      expect(titles(list(filter: { participant: [anna] }, search: 'Retro'))).to eq(['Beta Retro'])
    end

    it 'filters by creator and by the meeting date' do
      other = user_with_access('read_write', on: project_a)
      create_meeting(project: project_a, title: 'Other Creator', creator: other, occurred_at: 10.days.ago)

      expect(titles(list(filter: { creator: [other.id] }))).to eq(['Other Creator'])
      expect(titles(list(filter: { creator: [other.id] }, filter_op: { creator: 'not' }))).not_to include('Other Creator')
      expect(titles(list(filter: { occurred_at: ['last_7_days'] }))).to eq(['Beta Retro', 'Alpha Kickoff', 'Gamma Sync'])
    end

    it 'names the project in the chip sentence' do
      page = list(filter: { project: [project_b.id] })
      expect(page.find('#meetings_overview_results_sentence')).to have_text('Projekt Beta')
    end

    it 'searches the title only when the search depth says so' do
      ActsAsTenant.with_tenant(organisation) { alpha.update!(notes: 'Retro im Text') }
      expect(titles(list(search: 'Retro', search_mode: 'title_only'))).to eq(['Beta Retro'])
    end

    it 'offers "Projekt" with "or" and "not", the two the list applies' do
      categories = JSON.parse(list.find('[data-controller="filter-bar"]')['data-filter-bar-categories-value'])
      expect(categories.find { |category| category['key'] == 'project' }['allowed_operators']).to eq(%w[or not])
    end

    it 'reads an empty or malformed project value as no condition' do
      all = ['Beta Retro', 'Alpha Kickoff', 'Gamma Sync']
      expect(titles(list(filter: { project: [''] }))).to eq(all)
      expect(titles(list(filter: { project: [{ 'a' => project_a.id }] }))).to eq(all)
    end

    it 'reads a search of the wrong shape as no search' do
      expect(titles(list(search: { 'a' => 'Retro' }))).to eq(['Beta Retro', 'Alpha Kickoff', 'Gamma Sync'])
    end
  end

  describe 'old addresses' do
    before { sign_in reader }

    it 'turns ?participant= and ?project_id= into the bar conditions' do
      create_meeting(project: project_a, title: 'Alpha Kickoff', participants: ['Anna Mueller'])
      create_meeting(project: project_b, title: 'Beta Retro', participants: ['Anna Mueller'])
      anna = MeetingParticipant.normalize_name('Anna Müller')

      get overview_path, params: { participant: anna, project_id: project_a.id, search: 'Kick' }
      expect(response).to redirect_to(organisation_meetings_path(organisation, filter: { participant: [anna], project: [project_a.id] }, search: 'Kick'))

      follow_redirect!
      expect(titles).to eq(['Alpha Kickoff'])
    end

    it 'drops an old filter that is not a single value instead of failing' do
      get overview_path, params: { project_id: { 'a' => '1' } }
      expect(response).to redirect_to(overview_path)
    end

    it 'lets a condition the address already carries win over the old parameter' do
      get overview_path, params: { project_id: project_a.id, filter: { project: [project_b.id] } }
      expect(response).to redirect_to(organisation_meetings_path(organisation, filter: { project: [project_b.id] }))
    end
  end

  describe 'columns, sort and pages' do
    before { sign_in reader }

    it 'shows title, project, meeting date, duration and participants' do
      create_meeting(project: project_b, title: 'Beta Retro', participants: ['Bert Berg'], duration_minutes: 45)
      page = list

      expect(page.all('#meetings_overview_results thead th').map { |head| head['data-column'] })
        .to eq(%w[title project occurred_at duration_minutes participants])
      row = page.find('#meetings_overview_results tr[data-meeting-id]')
      expect(row).to have_css('td[data-column="project"]', text: 'Projekt Beta')
      expect(row).to have_css('td[data-column="participants"]', text: 'Bert Berg')
    end

    it 'sorts by a column head, keeping the filters' do
      create_meeting(project: project_a, title: 'Bravo', occurred_at: 1.day.ago)
      create_meeting(project: project_a, title: 'Alpha', occurred_at: 2.days.ago)
      create_meeting(project: project_b, title: 'Charlie', occurred_at: 3.days.ago)

      page = list(filter: { project: [project_a.id] })
      link = page.find('#meetings_overview_results th[data-column="title"] a')
      query = Rack::Utils.parse_nested_query(URI.parse(link[:href]).query)
      expect(URI.parse(link[:href]).path).to eq(overview_path)
      expect(query).to include('sort' => { 'column' => 'title', 'direction' => 'asc' }, 'filter' => { 'project' => [project_a.id] })
      expect(link['data-turbo-frame']).to eq('meetings_overview_results')

      expect(titles(list(filter: { project: [project_a.id] }, sort: { column: 'title', direction: 'asc' }))).to eq(%w[Alpha Bravo])
    end

    it 'pages through the list with the filters kept' do
      Prosopite.pause do
        3.times { |index| create_meeting(project: project_a, title: "Seite #{index}", occurred_at: index.days.ago) }
      end

      page = list(items: 2, filter: { project: [project_a.id] })
      expect(titles(page).size).to eq(2)
      next_link = page.find("#meetings_overview_results a[title='#{I18n.t('views.shared.pagination_compact.next_page')}']")
      expect(URI.parse(next_link[:href]).path).to eq(overview_path)
      expect(Rack::Utils.parse_nested_query(URI.parse(next_link[:href]).query)).to include('page' => '2', 'filter' => { 'project' => [project_a.id] })

      expect(titles(list(items: 2, page: 2, filter: { project: [project_a.id] }))).to eq(['Seite 2'])
    end

    it 'carries only the list state into the page links, not every word of the address' do
      Prosopite.pause do
        3.times { |index| create_meeting(project: project_a, title: "Seite #{index}", occurred_at: index.days.ago) }
      end

      page = list(items: 2, utm_source: 'newsletter')
      next_link = page.find("#meetings_overview_results a[title='#{I18n.t('views.shared.pagination_compact.next_page')}']")
      query = Rack::Utils.parse_nested_query(URI.parse(next_link[:href]).query)
      expect(query).to include('page' => '2', 'items' => '2')
      expect(query).not_to have_key('utm_source')
    end

    # One writer of the address, the project page's (PR 3): layout-toggle
    # copies the list state the frame rendered into the address after every
    # reload and stream. list-address, the writer of PR 1, is gone.
    it 'lets the address follow the list frame, so the bar reads sort and page from it' do
      create_meeting(project: project_a, title: 'Alpha Kickoff')
      page = list

      wrapper = page.find('[data-controller~="layout-toggle"]')
      expect(JSON.parse(wrapper['data-layout-toggle-list-frame-ids-value'])).to eq(['meetings_overview_results'])
      expect(JSON.parse(wrapper['data-layout-toggle-list-filter-params-value'])).to eq(Meetings::ListState::KEYS)
      expect(wrapper['data-index-url']).to eq(overview_path)
      expect(page).to have_no_css('[data-controller~="list-address"]')
    end

    it 'answers the list frame alone' do
      create_meeting(project: project_a, title: 'Alpha Kickoff')
      get overview_path, headers: { 'Turbo-Frame' => 'meetings_overview_results' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<turbo-frame id="meetings_overview_results"', 'Alpha Kickoff')
      expect(response.body).not_to include('data-controller="filter-bar"')
    end

    # The bar reloads its chip sentence through a frame of its own after every
    # change; a full page in its place would put a second list into the head.
    it 'answers the sentence frame of the bar alone' do
      create_meeting(project: project_a, title: 'Alpha Kickoff')
      get overview_path, params: { filter: { project: [project_a.id] } },
                         headers: { 'Turbo-Frame' => 'meetings_overview_results_sentence' }

      expect(response).to have_http_status(:ok)
      expect(page_body).to have_css('turbo-frame#meetings_overview_results_sentence', text: 'Projekt Alpha')
      expect(response.body).not_to include('<turbo-frame id="meetings_overview_results"')
    end
  end

  describe 'the project page next to it' do
    it 'lists only the meetings of its own project, also for a reader of both' do
      alpha = create_meeting(project: project_a, title: 'Alpha Kickoff')
      create_meeting(project: project_b, title: 'Beta Retro')
      sign_in reader
      get organisation_project_meetings_path(organisation, project_a)

      expect(response).to have_http_status(:ok)
      expect(page_body.all('#meetings_results tr[data-meeting-id]').map { |row| row['data-meeting-id'] }).to eq([alpha.id])
    end
  end

  describe 'row navigation' do
    # Since PR 3 the row opens the meeting in the lane of this page
    # (meetings_overview_lane_spec.rb), no longer on its project's page.
    it 'opens a row in the lane of this page, through the detail of its project' do
      meeting = create_meeting(project: project_a, title: 'Alpha Kickoff')
      sign_in reader
      page = list

      row = page.find("#meetings_overview_results tr[data-meeting-id='#{meeting.id}']")
      expect(row['data-list-row-url-value']).to eq(organisation_project_meeting_path(organisation, project_a, meeting, list_context: 'organisation'))
      expect(row['data-list-row-frame-value']).to eq('meeting_display_frame')
    end
  end

  describe 'phone' do
    # The project page's phone list (PR 2): the table with no ranked column in
    # its head, every pinned value under the title, and the picker beside it.
    it 'folds every column under the title and keeps the project and participants readable there' do
      create_meeting(project: project_a, title: 'Alpha Kickoff', participants: ['Anna Mueller'])
      sign_in reader
      page = list(viewport: 'mobile')

      expect(page).to have_css('[data-controller="filter-bar"] [data-column-picker-trigger]')
      expect(page).to have_css('.meeting-mobile-grid #column-picker', visible: :all)
      expect(page).to have_css('#meetings_overview_results table[data-fit="0"]')
      row = page.find('#meetings_overview_results tr[data-meeting-id]', text: 'Alpha Kickoff')
      shown = row.all('.ticket-meta__item:not([hidden])').map { |item| item.text.strip }
      expect(shown).to eq(['Projekt Alpha', 'Anna Mueller'])
    end
  end

  describe 'performance (no N+1 across rows)' do
    it 'renders meetings from several projects without an N+1 on project, creator or participants' do
      Prosopite.pause do
        create_meeting(project: project_a, title: 'Alpha One', participants: ['Anna Mueller'])
        create_meeting(project: project_a, title: 'Alpha Two', participants: ['Bob Builder'])
        create_meeting(project: project_b, title: 'Beta One', participants: ['Clara Klein'])
      end

      sign_in reader
      get overview_path
      expect(response).to have_http_status(:ok)
      expect(titles).to contain_exactly('Alpha One', 'Alpha Two', 'Beta One')
    end
  end

  describe 'empty states' do
    before { sign_in reader }

    it 'shows the first-time empty state when there are no meetings at all, below the filter bar' do
      page = list
      expect(response.body).to include(I18n.t('views.organisations.meetings_overview.index.empty_first_time_title'))
      # The bar stands from the start: a save from the "+" replaces only the
      # list frame, and a bar missing until a full reload is a page without its tools.
      expect(page).to have_css('[data-controller="filter-bar"]')
    end

    it 'shows the no-results empty state when a filter matches nothing' do
      create_meeting(project: project_a, title: 'Alpha Kickoff')
      list(search: 'zzz-nothing-matches')
      expect(response.body).to include(I18n.t('views.organisations.meetings.index.empty_no_results'))
    end
  end

  describe 'navigation entry visibility (can_view_meetings gate)' do
    let(:tickets_permission) do
      user = create(:user)
      permission = nil
      ActsAsTenant.with_tenant(organisation) do
        role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
        create(:membership, user: user, organisation: organisation, role: role, active: true)
        permission = create(:project_permission, user: user, project: project_a, tickets_access: 'read_only')
      end
      permission
    end
    let(:tickets_user) { tickets_permission.user }
    let(:sidebar_path) { organisation_project_tickets_path(organisation, project_a) }

    it 'hides "Alle Meetings" from a sidebar user without meetings access' do
      sign_in tickets_user
      get sidebar_path
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t('navigation.all_meetings'))
    end

    it 'shows "Alle Meetings" once the same user gains meetings read access' do
      ActsAsTenant.with_tenant(organisation) { tickets_permission.update!(meetings_access: 'read_only') }
      sign_in tickets_user
      get sidebar_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('navigation.all_meetings'))
    end
  end

  describe 'navigation collapsible group ("Zeiten" / "Alle Meetings")' do
    let(:base_permission) do
      user = create(:user)
      permission = nil
      ActsAsTenant.with_tenant(organisation) do
        role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
        create(:membership, user: user, organisation: organisation, role: role, active: true)
        permission = create(:project_permission, user: user, project: project_a, tickets_access: 'read_only')
      end
      permission
    end
    let(:sidebar_user) { base_permission.user }
    let(:sidebar_path) { organisation_project_tickets_path(organisation, project_a) }
    let(:times_path) { organisation_time_sessions_path(organisation) }

    def more_item_wrapping(path)
      /data-more-item[^>]*>\s*<a[^>]*#{Regexp.escape(path)}/m
    end

    def grant_time_access!
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session_permission, user: sidebar_user, project: project_a, can_view_own: true)
      end
    end

    def grant_meetings_access!
      ActsAsTenant.with_tenant(organisation) { base_permission.update!(meetings_access: 'read_only') }
    end

    it 'shows "Zeiten" AND "Alle Meetings" inline, "Zeiten" first, no "mehr …" reveal' do
      grant_time_access!
      grant_meetings_access!
      sign_in sidebar_user
      get sidebar_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('navigation.times'), I18n.t('navigation.all_meetings'))
      expect(response.body).not_to match(more_item_wrapping(times_path))
      expect(response.body).not_to match(more_item_wrapping(overview_path))
      expect(response.body.index(I18n.t('navigation.times'))).to be < response.body.index(I18n.t('navigation.all_meetings'))
    end
  end
end
