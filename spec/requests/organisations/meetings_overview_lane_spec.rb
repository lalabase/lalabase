# frozen_string_literal: true

require 'rails_helper'

# "Alle Meetings" with the detail in the lane (doc/meetings_uebersicht_vereinheitlichen_plan.md,
# PR 3): a row opens the meeting beside the list, as on the project page, and a
# save in the lane redraws the list the lane was opened from. The detail and its
# writes stay project-nested (MeetingsController); the lane only says which list
# it belongs to, with list_context=organisation. What the lane may reveal is
# pinned by meetings_overview_lane_access_spec.rb; this file is about behaviour.
RSpec.describe 'Organisations::MeetingsOverview lane', type: :request do
  before { Prosopite.pause } # several requests and setup writes per example
  after { Prosopite.resume }

  let(:organisation) { create(:organisation, ai_enabled: true) }
  let(:project_a) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Alpha') } }
  let(:project_b) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Beta') } }
  let(:overview_path) { organisation_meetings_path(organisation) }
  let(:user) { create(:user) }

  let!(:alpha) { create_meeting(project: project_a, title: 'Alpha Kickoff', occurred_at: 2.days.ago, participants: ['Anna']) }
  let!(:beta) { create_meeting(project: project_b, title: 'Beta Retro', occurred_at: 1.day.ago, participants: ['Anna']) }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation), active: true)
    end
    sign_in user
  end

  def create_meeting(project:, title:, participants: [], **attributes)
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting, project: project, organisation: organisation, creator: user, title: title, **attributes).tap do |meeting|
        participants.each { |name| create(:meeting_participant, meeting: meeting, display_name: name) }
      end
    end
  end

  def page_body = Capybara.string(response.body)

  def overview_titles(doc = page_body)
    doc.all('#meetings_overview_results tr[data-meeting-id] h5').map { |title| title.text.strip }
  end

  # The targets of the response's streams, by action.
  def stream_targets(action)
    page_body.all("turbo-stream[action='#{action}']").map { |stream| stream['target'] }
  end

  # What a stream renders. Capybara does not walk a <template>, so its content
  # is read from the raw body.
  def stream_content(action, target)
    match = response.body.match(%r{<turbo-stream action="#{action}" target="#{target}"><template>(.*?)</template></turbo-stream>}m)
    expect(match).not_to be_nil, "no #{action} stream for #{target}"
    Capybara.string(match[1])
  end

  def streamed_titles(target)
    stream_content('replace', target).all("##{target} tr[data-meeting-id] h5").map { |title| title.text.strip }
  end

  def query_of(href) = Rack::Utils.parse_nested_query(URI(href).query)

  def lane_query = { list_context: 'organisation' }

  describe 'the page' do
    it 'is the project page layout: list, lane and one writer of the address' do
      get overview_path

      wrapper = page_body.find('.labor-layout-view')
      expect(wrapper['data-controller'].split).to include('layout-toggle', 'hover-arrows', 'index-page', 'keyboard-navigation', 'viewport', 'column-picker')
      expect(wrapper['data-controller'].split).not_to include('list-address')
      expect(wrapper['data-index-url']).to eq(overview_path)
      expect(JSON.parse(wrapper['data-layout-toggle-list-frame-ids-value'])).to eq(['meetings_overview_results'])
      expect(wrapper['data-layout-toggle-detail-frame-id-value']).to eq('meeting_display_frame')
      expect(JSON.parse(wrapper['data-layout-toggle-list-filter-params-value'])).to eq(Meetings::ListState::KEYS)
      expect(wrapper['data-viewport-breakpoint-value']).to eq('1024')
      expect(page_body).to have_css('turbo-frame#meeting_display_frame')
      expect(page_body).to have_css("turbo-frame#meetings_overview_results[data-keyboard-navigation-target='listContainer']")
    end

    # A link the server renders without the request's context (a broadcast, a
    # section refresh) must still carry it: layout-toggle adds the lane context
    # to every request of the lane at click and submit.
    it 'gives the lane its context as data, and the project page none' do
      get overview_path

      wrapper = page_body.find('.labor-layout-view')
      expect(JSON.parse(wrapper['data-layout-toggle-lane-context-value'])).to eq('list_context' => 'organisation')

      get organisation_project_meetings_path(organisation, project_a)

      wrapper = page_body.find('.labor-layout-view')
      expect(wrapper['data-layout-toggle-list-frame-ids-value']).to be_present
      expect(wrapper['data-layout-toggle-lane-context-value']).to be_nil
    end

    it 'opens a row in the lane: list-row with the project-nested detail address and the context' do
      get overview_path

      row = page_body.find("tr[data-meeting-id='#{beta.id}']")
      expect(row['data-controller']).to eq('list-row')
      expect(row['data-action']).to eq('click->list-row#click')
      expect(row['data-list-row-frame-value']).to eq('meeting_display_frame')
      expect(row['data-list-row-param-value']).to eq('meeting_id')
      expect(row['data-list-row-url-value'])
        .to eq(organisation_project_meeting_path(organisation, project_b, beta, list_context: 'organisation'))
      expect(page_body).to have_no_css('[data-controller~="clickable-row"]')
    end
  end

  describe 'a full visit with ?meeting_id=' do
    it 'opens the meeting in the lane and keeps meetings of every project in the list' do
      get overview_path, params: { meeting_id: alpha.id, search: 'a' }

      expect(response).to have_http_status(:ok)
      expect(page_body).to have_css('.labor-layout-view.show-content')
      expect(page_body).to have_css('#meeting_display_frame h2', text: 'Alpha Kickoff')
      expect(page_body).to have_css("tr.selected-row[data-meeting-id='#{alpha.id}']")
      # @project of the lane never becomes the list's project.
      expect(overview_titles).to contain_exactly('Alpha Kickoff', 'Beta Retro')
    end

    it 'gives the lane the way back to this list, with its state, and every write the context' do
      get overview_path, params: { meeting_id: alpha.id, search: 'Kick', search_mode: 'title_only' }

      back = page_body.find('#meeting_display_frame [data-lane-back]')['href']
      expect(URI(back).path).to eq(overview_path)
      expect(query_of(back)).to include('search' => 'Kick', 'search_mode' => 'title_only')
      expect(query_of(back)).not_to include('list_context', 'meeting_id')
      # The lane's own routes are its project's (layout_toggle hands them the list state).
      head = page_body.find('#meeting_display_frame [data-lane-head]')
      expect(head['data-lane-index-url']).to eq(organisation_project_meetings_path(organisation, project_a))
      edit = query_of(page_body.find("#meeting_display_frame a[title='#{I18n.t('views.organisations.meetings.show.edit_meeting')}']", match: :first)['href'])
      expect(edit).to include('list_context' => 'organisation', 'search' => 'Kick', 'search_mode' => 'title_only')
    end

    # The address must only name what the server opened: a selection it could
    # not resolve would make layout-toggle and index-page open an empty lane.
    it 'names a meeting_id it could not resolve, so the page takes it out of the address' do
      deleted_id = SecureRandom.uuid
      get overview_path, params: { meeting_id: deleted_id, search: 'a' }

      expect(response).to have_http_status(:ok)
      wrapper = page_body.find('.labor-layout-view')
      expect(wrapper[:class].split).not_to include('show-content')
      expect(JSON.parse(wrapper['data-layout-toggle-unresolved-selection-value'])).to eq('meeting_id' => deleted_id)

      get overview_path, params: { meeting_id: alpha.id }

      wrapper = page_body.find('.labor-layout-view.show-content')
      expect(wrapper['data-layout-toggle-unresolved-selection-value']).to be_nil
    end

    it 'does the same on the project page, for a meeting_id and for a new form it did not open' do
      get organisation_project_meetings_path(organisation, project_a), params: { meeting_id: beta.id }

      wrapper = page_body.find('.labor-layout-view')
      expect(wrapper[:class].split).not_to include('show-content')
      expect(JSON.parse(wrapper['data-layout-toggle-unresolved-selection-value'])).to eq('meeting_id' => beta.id)

      get organisation_project_meetings_path(organisation, project_a), params: { meeting_id: alpha.id, new: 'meeting' }

      wrapper = page_body.find('.labor-layout-view.show-content')
      expect(JSON.parse(wrapper['data-layout-toggle-unresolved-selection-value'])).to eq('new' => 'meeting')

      get organisation_project_meetings_path(organisation, project_a), params: { new: 'meeting' }

      wrapper = page_body.find('.labor-layout-view.show-content')
      expect(wrapper['data-layout-toggle-unresolved-selection-value']).to be_nil
    end

    it 'recovers a stuck ticket suggestion run as the project page does' do
      allow(MeetingTicketSuggestionRun).to receive(:recover_for_meeting!).and_call_original

      get overview_path, params: { meeting_id: alpha.id }

      expect(MeetingTicketSuggestionRun).to have_received(:recover_for_meeting!).with(alpha)
    end

    it 'opens nothing without the parameter' do
      get overview_path

      expect(page_body).to have_css('#meeting_display_frame')
      expect(page_body).to have_no_css('.labor-layout-view.show-content')
      expect(page_body).to have_no_css('#meeting_display_frame h2')
    end
  end

  describe 'the detail loaded into the lane (frame: content)' do
    it 'renders the way back to the overview and carries the context in its links' do
      ActsAsTenant.with_tenant(organisation) { alpha.update!(notes: 'Etwas Inhalt') }
      get organisation_project_meeting_path(organisation, project_a, alpha, frame: 'content', list_context: 'organisation', search: 'Kick'),
          headers: { 'Turbo-Frame' => 'meeting_display_frame' }

      expect(response).to have_http_status(:ok)
      back = page_body.find('[data-lane-back]')['href']
      expect(URI(back).path).to eq(overview_path)
      expect(query_of(back)).to include('search' => 'Kick')
      expect(query_of(back)).not_to include('list_context')
      toggle = page_body.find("form[action='#{toggle_search_organisation_project_meeting_path(organisation, project_a, alpha)}']")
      expect(toggle).to have_css("input[name='list_context'][value='organisation']", visible: :all)
    end

    it 'keeps the project page back link without the context' do
      ActsAsTenant.with_tenant(organisation) { alpha.update!(notes: 'Etwas Inhalt') }
      get organisation_project_meeting_path(organisation, project_a, alpha, frame: 'content', search: 'Kick'),
          headers: { 'Turbo-Frame' => 'meeting_display_frame' }

      back = page_body.find('[data-lane-back]')['href']
      expect(URI(back).path).to eq(organisation_project_meetings_path(organisation, project_a))
      expect(query_of(back)).to include('search' => 'Kick')
      expect(page_body).to have_css("form[action^='#{toggle_search_organisation_project_meeting_path(organisation, project_a, alpha)}']")
      expect(page_body).to have_no_css("input[name='list_context']", visible: :all)
    end

    it 'puts the context into the edit form, its delete and its cancel' do
      get edit_organisation_project_meeting_path(organisation, project_a, alpha, format: :turbo_stream, frame_id: 'meeting_display_frame',
                                                                                 list_context: 'organisation', search: 'Kick')

      form_doc = stream_content('update', 'meeting_display_frame')
      save = form_doc.find("form[action='#{organisation_project_meeting_path(organisation, project_a, alpha, format: :turbo_stream)}']")
      expect(save).to have_css("input[name='list_context'][value='organisation']", visible: :all)
      expect(save).to have_css("input[name='search'][value='Kick']", visible: :all)
      # The delete button's form sits inside the edit form, which the parser
      # flattens: its action is read from the raw body.
      delete_action = CGI.unescapeHTML(response.body[/<form[^>]*class="button_to"[^>]*action="([^"]+)"/, 1].to_s)
      expect(URI(delete_action).path).to eq(organisation_project_meeting_path(organisation, project_a, alpha))
      expect(query_of(delete_action)).to include('list_context' => 'organisation', 'search' => 'Kick')
      cancel = form_doc.find('a', text: I18n.t('views.organisations.meetings.form.cancel'))
      expect(query_of(cancel['href'])).to include('list_context' => 'organisation', 'frame' => 'content')
    end
  end

  describe 'a save from the lane' do
    def update_alpha(context: lane_query, **list_state)
      patch organisation_project_meeting_path(organisation, project_a, alpha, format: :turbo_stream),
            params: { meeting: { title: 'Alpha Kickoff neu' }, frame_id: 'meeting_display_frame' }.merge(context).merge(list_state)
    end

    it 'redraws the overview list with its filters, not the project list' do
      update_alpha(filter: { participant: ['Anna'] })

      expect(response).to have_http_status(:ok)
      expect(stream_targets('replace')).to include('meetings_overview_results')
      expect(stream_targets('replace')).not_to include('meetings_results')
      expect(streamed_titles('meetings_overview_results')).to contain_exactly('Alpha Kickoff neu', 'Beta Retro')
      list = stream_content('replace', 'meetings_overview_results')
      expect(list).to have_css("tr.selected-row[data-meeting-id='#{alpha.id}']")
      state = Rack::Utils.parse_nested_query(list.find('[data-list-filter-query]')['data-list-filter-query'])
      expect(state).to include('filter' => { 'participant' => ['Anna'] })
      expect(state).not_to have_key('list_context')
      expect(stream_content('update', 'meeting_display_frame')).to have_css('h2', text: 'Alpha Kickoff neu')
    end

    it 'leaves a meeting that no longer matches open in the lane and out of the list' do
      update_alpha(search: 'Beta')

      expect(streamed_titles('meetings_overview_results')).to eq(['Beta Retro'])
      expect(stream_content('update', 'meeting_display_frame')).to have_css('h2', text: 'Alpha Kickoff neu')
    end

    it 'redraws the project list without the context, as before' do
      update_alpha(context: {})

      expect(stream_targets('replace')).to include('meetings_results')
      expect(stream_targets('replace')).not_to include('meetings_overview_results')
      expect(streamed_titles('meetings_results')).to eq(['Alpha Kickoff neu'])
    end

    it 'goes back to the overview without JavaScript' do
      patch organisation_project_meeting_path(organisation, project_a, alpha),
            params: { meeting: { title: 'Alpha neu' }, list_context: 'organisation', search: 'Alpha' }

      expect(response).to redirect_to(organisation_meetings_path(organisation, search: 'Alpha', meeting_id: alpha.id))
    end

    it 'deletes: the overview list loses the meeting and the lane closes' do
      delete organisation_project_meeting_path(organisation, project_a, alpha, format: :turbo_stream, list_context: 'organisation')

      expect(streamed_titles('meetings_overview_results')).to eq(['Beta Retro'])
      expect(stream_targets('replace')).not_to include('meetings_results')
      expect(page_body).to have_css("turbo-stream[action='closeLane']")
    end

    it 'flips the search release and redraws the overview list' do
      ActsAsTenant.with_tenant(organisation) { alpha.update!(notes: 'Etwas Inhalt') }

      post toggle_search_organisation_project_meeting_path(organisation, project_a, alpha, format: :turbo_stream),
           params: { create_embeddings: '1', list_context: 'organisation' }

      expect(response).to have_http_status(:ok)
      expect(stream_targets('replace')).to include('meetings_overview_results', "meeting_#{alpha.id}_search_status")
      expect(stream_targets('replace')).not_to include('meetings_results')
    end

    it 'starts a summary without touching any list, and goes back to the overview without JavaScript' do
      ActsAsTenant.with_tenant(organisation) { alpha.update!(notes: 'Etwas Inhalt') }
      allow_any_instance_of(Organisation).to receive(:ai_available_for?).and_call_original
      allow_any_instance_of(Organisation).to receive(:ai_available_for?).with(:meeting_summary).and_return(
        Lalabase::Llm::FeatureRegistry::Availability.new(available: true, reason: nil)
      )
      allow(Meetings::SummaryJob).to receive(:perform_later)

      post create_summary_organisation_project_meeting_path(organisation, project_a, alpha),
           params: { list_context: 'organisation', search: 'Alpha' }

      expect(response).to redirect_to(organisation_meetings_path(organisation, search: 'Alpha', meeting_id: alpha.id))
    end
  end

  describe 'saving a view with a meeting open in the lane' do
    it 'lets the filter bar carry the open meeting, and the save return with it open' do
      get overview_path, params: { meeting_id: alpha.id, search: 'Alpha' }

      bar = page_body.find('[data-controller~="filter-bar"]')
      expect(JSON.parse(bar['data-filter-bar-return-keys-value'])).to include('meeting_id', *Meetings::ListState::KEYS)

      post create_from_filters_organisation_smart_folders_path(organisation), params: {
        return_to: 'meetings', target_object_type: 'Meeting', smart_folder_name: 'Mit Anna',
        filter: { participant: ['Anna'] }, list_context: { search: 'Alpha', meeting_id: alpha.id }
      }

      expect(query_of(response.location)).to include('meeting_id' => alpha.id, 'search' => 'Alpha')
      follow_redirect!
      expect(page_body).to have_css('#meeting_display_frame h2', text: 'Alpha Kickoff')
    end
  end

  describe 'the context the lane forwards' do
    it 'sends a full page of the project route with the context to the overview' do
      get organisation_project_meetings_path(organisation, project_a, list_context: 'organisation', search: 'Kick', meeting_id: alpha.id)

      expect(response).to redirect_to(organisation_meetings_path(organisation, search: 'Kick', meeting_id: alpha.id))
    end

    it 'sends a full visit of the detail with the context to the overview with the meeting open' do
      get organisation_project_meeting_path(organisation, project_a, alpha, list_context: 'organisation')

      expect(response).to redirect_to(organisation_meetings_path(organisation, meeting_id: alpha.id))
    end
  end

  describe 'on a phone' do
    it 'shows the meeting full width with the way back to the overview and its filters' do
      get overview_path, params: { meeting_id: alpha.id, viewport: 'mobile', search: 'Kick' }

      expect(response).to have_http_status(:ok)
      expect(page_body).to have_css('#meeting_display_frame h2', text: 'Alpha Kickoff')
      back = page_body.find('.mobile-ticket-view a', text: I18n.t('views.organisations.meetings.index.mobile_list_view'), match: :first)
      expect(back['href']).to eq(organisation_meetings_path(organisation, viewport: 'mobile', search: 'Kick'))
      expect(page_body).to have_no_css('#meetings_overview_results tr[data-meeting-id]')
    end

    it 'shows the list with rows that open in the lane' do
      get overview_path, params: { viewport: 'mobile' }

      expect(overview_titles).to contain_exactly('Alpha Kickoff', 'Beta Retro')
      expect(page_body.find("tr[data-meeting-id='#{alpha.id}']")['data-controller']).to eq('list-row')
    end
  end
end
