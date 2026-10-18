# frozen_string_literal: true

require 'rails_helper'

# Creating a meeting from the ORG-WIDE list ("Alle Meetings"). A meeting always
# belongs to a project and this page has none, so the "+" opens the lane with a
# project select (MeetingsOverviewController#index, ?new=meeting), and the frame
# below the select loads THAT project's real form (MeetingsController#new,
# frame: 'content'). Since PR 4 of doc meetings_uebersicht_vereinheitlichen_plan.md
# this is the lane, as on the project page; until then it was a modal.
#
# Four guarantees carry the feature, and none is visible from the project page's
# own specs:
#
#   1. One address for the lane with the select, for a full visit and for the
#      lane frame alike: the overview with ?new=meeting. Exactly one writable
#      project is chosen at once and its form loads.
#   2. The form inside the select's frame is the project page's form without
#      its lane head (the select's lane has one), and it carries the list it was
#      opened from: list_context=organisation and the list state.
#   3. A save opens the new meeting in the lane and redraws THIS list, with the
#      overview address carrying meeting_id, as on the project page. The list
#      frame is replaced and must bring its <turbo-frame> along, or every later
#      stream to it would vanish without a word.
#   4. A refused save answers into the select's frame, so the select keeps its
#      project. Rights: meetings_overview_new_access_spec.rb.
RSpec.describe 'Organisations::MeetingsOverview create', type: :request do
  before { Prosopite.pause } # several requests and setup writes per example
  after { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:project_a) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Alpha') } }
  let(:project_b) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Beta') } }

  # `levels` maps project => meetings_access ('read_only' / 'read_write'). A project
  # left out of the hash grants nothing at all.
  def user_with(levels)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      levels.each { |project, level| create(:project_permission, user: user, project: project, meetings_access: level) }
    end
    user
  end

  let(:writer_a) { user_with(project_a => 'read_write') }
  let(:writer_both) { user_with(project_a => 'read_write', project_b => 'read_write') }
  let(:reader_a) { user_with(project_a => 'read_only') }

  let(:overview_path) { organisation_meetings_path(organisation) }
  let(:anna) { MeetingParticipant.normalize_name('Anna Müller') }
  let(:lane_frame) { { 'Turbo-Frame' => 'meeting_display_frame' } }

  # The creator is a caller's choice: hard-coding one silently drags an unrelated
  # user (and its role, membership and permissions) into every example.
  def create_meeting(project:, title:, creator: nil, participants: [], occurred_at: Time.current)
    ActsAsTenant.with_tenant(organisation) do
      meeting = create(:meeting, project: project, organisation: organisation,
                                 creator: creator || reader_a, title: title, occurred_at: occurred_at)
      participants.each { |name| create(:meeting_participant, meeting: meeting, display_name: name) }
      meeting
    end
  end

  def page_body = Capybara.string(response.body)

  def query_of(url) = Rack::Utils.parse_nested_query(URI.parse(url).query)

  def option_for(project)
    page_body.find("#meeting-new-project option[value='#{project.id}']", visible: :all)
  end

  def hidden_field_value(name)
    Nokogiri::HTML(response.body).at_css("input[type=hidden][name='#{name}']")&.[]('value')
  end

  def streams
    Nokogiri::HTML.fragment(response.body).css('turbo-stream')
  end

  def stream(action, target)
    streams.find { |node| node['action'] == action && node['target'] == target }
  end

  describe 'the "+"' do
    it 'opens the lane with the select at the overview address, from the address bar at click time' do
      sign_in writer_a
      get overview_path, params: { search: 'Kickoff' }

      plus = page_body.find("a[title='#{I18n.t('views.organisations.meetings_overview.index.new_meeting')}']")
      expect(plus['data-controller']).to eq('lane-link')
      expect(plus['data-lane-link-frame-value']).to eq('meeting_display_frame')
      expect(JSON.parse(plus['data-lane-link-set-value'])).to eq('new' => 'meeting')
      expect(JSON.parse(plus['data-lane-link-remove-value'])).to eq(['meeting_id'])
      expect(URI.parse(plus['data-lane-link-url-value']).path).to eq(overview_path)
      # The href is the same state for a page without JavaScript, or a new tab.
      expect(URI.parse(plus['href']).path).to eq(overview_path)
      expect(query_of(plus['href'])).to eq('new' => 'meeting', 'search' => 'Kickoff')
    end
  end

  describe 'the lane with the select (?new=meeting)' do
    it 'opens on a full visit, the list with its state beside it' do
      create_meeting(project: project_a, title: 'Alpha Kickoff', creator: writer_both)
      sign_in writer_both
      get overview_path, params: { new: 'meeting', search: 'Kickoff' }

      expect(response).to have_http_status(:ok)
      expect(page_body).to have_css('.labor-layout-view.show-content')
      expect(page_body).to have_css('#meetings_overview_results', text: 'Alpha Kickoff')
      expect(page_body).to have_css('#meeting_display_frame .meeting-content #meeting-new-project')
      expect(page_body).to have_css('#meeting_display_frame [data-lane-close]')
    end

    it 'answers the lane frame with the select alone, without the list' do
      create_meeting(project: project_a, title: 'Alpha Kickoff', creator: writer_both)
      sign_in writer_both
      get overview_path, params: { new: 'meeting', frame: 'content', frame_id: 'meeting_display_frame' }, headers: lane_frame

      expect(response).to have_http_status(:ok)
      expect(page_body).to have_css('turbo-frame#meeting_display_frame #meeting-new-project')
      expect(response.body).not_to include('meetings_overview_results', 'Alpha Kickoff')
    end

    it 'leaves the choice open with two projects, and loads no form yet' do
      sign_in writer_both
      get overview_path, params: { new: 'meeting' }

      expect(page_body.all('#meeting-new-project option[selected]', visible: :all)).to be_empty
      inner = page_body.find('turbo-frame#meeting_new_form')
      expect(inner['src']).to be_nil
      expect(inner['data-controller']).to include('frame-error')
      expect(inner).to have_text(I18n.t('views.organisations.meetings_overview.new_meeting.select_project_first'))
    end

    it 'chooses the one writable project at once and loads its form' do
      sign_in writer_a
      get overview_path, params: { new: 'meeting' }

      expect(option_for(project_a)['selected']).to be_present
      inner = page_body.find('turbo-frame#meeting_new_form')
      expect(inner['src']).to eq(option_for(project_a)['data-form-url'])
    end

    it 'leads each option to its project form in the select frame, with the list it was opened from' do
      sign_in writer_both
      get overview_path, params: { new: 'meeting', search: 'Kickoff', filter: { project: [project_b.id] }, viewport: 'desktop' }

      url = option_for(project_a)['data-form-url']
      expect(URI.parse(url).path).to eq(new_organisation_project_meeting_path(organisation, project_a))
      # The overview's own project condition travels as filter[project][], never
      # as project_id: that is the nested route's own parameter.
      expect(query_of(url)).to eq('frame' => 'content', 'frame_id' => 'meeting_new_form', 'list_context' => 'organisation',
                                  'search' => 'Kickoff', 'filter' => { 'project' => [project_b.id] }, 'viewport' => 'desktop')
    end

    it 'gives way to a meeting_id the server opens' do
      meeting = create_meeting(project: project_a, title: 'Alpha Kickoff', creator: writer_a)
      sign_in writer_a
      get overview_path, params: { new: 'meeting', meeting_id: meeting.id }

      expect(page_body).to have_css('#meeting_display_frame h2', text: 'Alpha Kickoff')
      expect(page_body).to have_no_css('#meeting-new-project')
    end

    it 'names new as a form state of the lane, and as unresolved where it did not open' do
      sign_in writer_a
      get overview_path, params: { new: 'meeting' }
      wrapper = page_body.find('.labor-layout-view')
      expect(JSON.parse(wrapper['data-lane-params'])['form']).to eq(['new'])
      expect(wrapper['data-layout-toggle-unresolved-selection-value']).to be_nil

      sign_in reader_a
      get overview_path, params: { new: 'meeting' }
      expect(JSON.parse(page_body.find('.labor-layout-view')['data-layout-toggle-unresolved-selection-value']))
        .to eq('new' => 'meeting')
    end
  end

  describe 'GET new into the frame of the select' do
    it 'renders the form without a lane head of its own, for the list it was opened from' do
      sign_in writer_a
      get new_organisation_project_meeting_path(organisation, project_a, frame: 'content', frame_id: 'meeting_new_form',
                                                                         list_context: 'organisation', search: 'Kickoff',
                                                                         filter: { participant: [anna], project: [project_b.id] }),
          headers: { 'Turbo-Frame' => 'meeting_new_form' }

      expect(response).to have_http_status(:ok)
      card = page_body.find('turbo-frame#meeting_new_form #meeting-form-card')
      expect(card).to have_css('form')
      expect(card).to have_no_css('[data-lane-close]')
      expect(card).to have_no_css('h2')
      # Which project index the form belongs to: layout-toggle sets the live list
      # state into its hidden fields at submit (lib/lane/filter_context).
      expect(card['data-lane-index-url']).to eq(organisation_project_meetings_path(organisation, project_a))
      expect(hidden_field_value('frame_id')).to eq('meeting_new_form')
      expect(hidden_field_value('list_context')).to eq('organisation')
      expect(hidden_field_value('search')).to eq('Kickoff')
      expect(hidden_field_value('filter[participant][]')).to eq(anna)
      expect(hidden_field_value('filter[project][]')).to eq(project_b.id)
    end

    it 'keeps the lane head when the form is the lane itself (the project page)' do
      sign_in writer_a
      get new_organisation_project_meeting_path(organisation, project_a, frame: 'content', frame_id: 'meeting_display_frame'),
          headers: lane_frame

      card = page_body.find('turbo-frame#meeting_display_frame #meeting-form-card')
      expect(card).to have_css('[data-lane-close]')
      expect(card).to have_css('h2', text: I18n.t('views.organisations.meetings.index.new_meeting'))
      expect(card['data-lane-index-url']).to be_nil
    end

    it 'falls back to the full page for an unknown frame value instead of half a page' do
      sign_in writer_a
      get new_organisation_project_meeting_path(organisation, project_a, frame: 'bogus'),
          headers: { 'Turbo-Frame' => 'meeting_new_form' }

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('<turbo-frame id="meeting_new_form"')
    end
  end

  describe 'POST create from the lane of the overview' do
    let(:valid_params) do
      { list_context: 'organisation', frame_id: 'meeting_new_form', meeting: { title: 'Kickoff Alpha', occurred_at: Time.current } }
    end

    def saved = ActsAsTenant.with_tenant(organisation) { Meeting.find_by!(title: 'Kickoff Alpha') }

    it 'opens the new meeting in the lane, in the redrawn overview, at an address with meeting_id' do
      sign_in writer_a

      expect do
        post organisation_project_meetings_path(organisation, project_a), params: valid_params.merge(search: 'Kickoff'), as: :turbo_stream
      end.to change { ActsAsTenant.with_tenant(organisation) { Meeting.count } }.by(1)

      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      address = URI.parse(stream('replaceAddress', 'meeting_display_frame')['url'])
      expect(address.path).to eq(overview_path)
      expect(Rack::Utils.parse_nested_query(address.query)).to eq('search' => 'Kickoff', 'meeting_id' => saved.id)

      list = stream('replace', 'meetings_overview_results')
      expect(list.at_css("tr.selected-row[data-meeting-id='#{saved.id}']")).to be_present
      lane = stream('update', 'meeting_display_frame')
      expect(lane.at_css('h2').text).to include('Kickoff Alpha')
      expect(response.body).to include(I18n.t('flash.meetings.created'))
      # Not into the frame of the select: the lane shows the meeting, the select goes.
      expect(stream('update', 'meeting_new_form')).to be_nil
      expect(response.body).not_to include('target="meetings_results"')
    end

    it 'leaves the results turbo-frame in place, so the page still works afterwards' do
      sign_in writer_a

      2.times do |i|
        post organisation_project_meetings_path(organisation, project_a),
             params: valid_params.deep_merge(meeting: { title: "Kickoff #{i}" }), as: :turbo_stream

        expect(response.body).to include('<turbo-frame id="meetings_overview_results"')
      end

      expect(response.body).to include('Kickoff 0', 'Kickoff 1')
    end

    it 'keeps an active participant filter in the redrawn list' do
      create_meeting(project: project_a, title: 'Alpha Kickoff', creator: writer_a, participants: ['Anna Müller'])
      create_meeting(project: project_a, title: 'Beta Sync', creator: writer_a, participants: ['Bert Berg'])
      sign_in writer_a

      post organisation_project_meetings_path(organisation, project_a),
           params: valid_params.merge(filter: { participant: [anna] }), as: :turbo_stream

      list = stream('replace', 'meetings_overview_results')
      expect(list.text).to include('Alpha Kickoff')
      expect(list.text).not_to include('Beta Sync')
    end

    it 'keeps an active project filter, says the new meeting is hidden by it, and still opens it' do
      # The save deliberately goes into a DIFFERENT project than the filter names:
      # reading params[:project_id] instead would silently pick up the nested
      # route's own parameter (the project being saved into) and look right.
      create_meeting(project: project_a, title: 'Alpha Kickoff', creator: writer_both)
      create_meeting(project: project_b, title: 'Beta Retro', creator: writer_both)
      sign_in writer_both

      post organisation_project_meetings_path(organisation, project_a),
           params: valid_params.merge(filter: { project: [project_b.id] }), as: :turbo_stream

      list = stream('replace', 'meetings_overview_results')
      expect(list.text).to include('Beta Retro')
      expect(list.text).not_to include('Alpha Kickoff', 'Kickoff Alpha')
      expect(response.body).to include(I18n.t('flash.meetings.created_hidden_by_filter'))
      expect(response.body).not_to include(I18n.t('flash.meetings.created'))
      expect(stream('update', 'meeting_display_frame').at_css('h2').text).to include('Kickoff Alpha')
      expect(query_of(stream('replaceAddress', 'meeting_display_frame')['url'])).to include('meeting_id' => saved.id)
    end

    it 'keeps an active saved view of the overview in the redrawn list' do
      create_meeting(project: project_b, title: 'Beta Retro', creator: writer_both)
      view = ActsAsTenant.with_tenant(organisation) do
        create(:smart_folder, name: 'Nur Beta', user: writer_both, organisation: organisation, project: nil,
                              target_object_type: 'Meeting').tap do |folder|
          folder.smart_folder_rule_groups.create!(position: 1)
                .smart_folder_rules.create!(field: 'project', operator: 'equals', value: project_b.id, position: 1)
        end
      end
      sign_in writer_both

      post organisation_project_meetings_path(organisation, project_b),
           params: valid_params.merge(smart_folder_id: view.id), as: :turbo_stream

      expect(stream('replace', 'meetings_overview_results').text).to include('Beta Retro', 'Kickoff Alpha')
      expect(response.body).to include(I18n.t('flash.meetings.created'))
    end

    it 'answers a filter of the wrong shape with a list, not a 500' do
      sign_in writer_a

      post organisation_project_meetings_path(organisation, project_a),
           params: valid_params.merge(filter: 'oops', sort: 'oops'), as: :turbo_stream

      expect(response).to have_http_status(:ok)
      expect(stream('replace', 'meetings_overview_results')).to be_present
    end

    it 'answers 422 into the frame of the select on an invalid submit, and creates nothing' do
      sign_in writer_a

      expect do
        post organisation_project_meetings_path(organisation, project_a),
             params: valid_params.deep_merge(meeting: { title: '' }), as: :turbo_stream
      end.not_to(change { ActsAsTenant.with_tenant(organisation) { Meeting.count } })

      expect(response).to have_http_status(:unprocessable_content)
      form = stream('update', 'meeting_new_form')
      expect(form.at_css('#meeting-form-card form')).to be_present
      expect(form.at_css('[data-lane-close]')).to be_nil
      # The select stands outside this frame and is not sent again: it keeps its project.
      expect(response.body).not_to include('meeting-new-project')
      expect(stream('update', 'meeting_display_frame')).to be_nil
    end
  end

  describe 'pages of the redrawn list' do
    it 'point to the overview, not to the project the meeting went into' do
      2.times { |index| create_meeting(project: project_a, title: "Alt #{index}", creator: writer_a) }
      sign_in writer_a

      post organisation_project_meetings_path(organisation, project_a),
           params: { list_context: 'organisation', frame_id: 'meeting_new_form',
                     meeting: { title: 'Kickoff Alpha', occurred_at: Time.current }, items: 2 },
           as: :turbo_stream

      next_link = Nokogiri::HTML(response.body).at_css("a[title='#{I18n.t('views.shared.pagination_compact.next_page')}']")
      expect(next_link).to be_present
      expect(URI.parse(next_link['href']).path).to eq(overview_path)
      expect(query_of(next_link['href'])).to include('page' => '2', 'items' => '2')
    end
  end

  describe 'POST create without turbo (no JavaScript)' do
    it 'sends a successful save back to the overview, with the new meeting open and the list state kept' do
      sign_in writer_a

      post organisation_project_meetings_path(organisation, project_a),
           params: { list_context: 'organisation', meeting: { title: 'Kickoff Alpha', occurred_at: Time.current },
                     filter: { project: [project_a.id] }, sort: { column: 'title', direction: 'asc' } }

      saved = ActsAsTenant.with_tenant(organisation) { Meeting.find_by!(title: 'Kickoff Alpha') }
      expect(URI.parse(response.location).path).to eq(overview_path)
      expect(query_of(response.location))
        .to include('filter' => { 'project' => [project_a.id] }, 'sort' => { 'column' => 'title', 'direction' => 'asc' },
                    'meeting_id' => saved.id)
    end

    # The frame below the select, as Turbo would get it, not the project page:
    # that page carries the same form card, so a check for the card alone
    # passed for either answer.
    it 'renders the form again on an invalid save, into the frame of the select' do
      sign_in writer_a

      post organisation_project_meetings_path(organisation, project_a),
           params: { list_context: 'organisation', frame_id: 'meeting_new_form', meeting: { title: '', occurred_at: Time.current } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(page_body).to have_css('turbo-frame#meeting_new_form #meeting-form-card form')
      expect(page_body).to have_no_css('#meetings_results, #meetings_overview_results')
      expect(page_body).to have_no_css('#meeting-form-card [data-lane-close]')
    end
  end
end
