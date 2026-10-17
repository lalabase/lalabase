# frozen_string_literal: true

require 'rails_helper'

# Creating a meeting from the ORG-WIDE list ("Alle Meetings", 05.09.2026). A meeting
# always belongs to a project and this page has none, so the "+" opens a modal that
# picks a project and then loads THAT project's real form into its frame.
#
# Three guarantees carry the feature, and none is visible from the project page's
# own specs:
#
#   1. The select must offer exactly the projects this person may WRITE meetings in.
#      Read access is not enough — the area gate would refuse the form, and the
#      button would be a promise without cover.
#   2. A save from the modal must refresh the ORG-WIDE list AND leave its frame in
#      place. This page has neither meetings_results nor meeting_display_frame, and
#      Turbo drops a stream whose target is missing WITHOUT a word. A `replace` whose
#      partial does not bring the <turbo-frame> deletes the frame, and from then on
#      the filter row and every LATER save hit exactly that silent drop.
#   3. The list state must survive the whole round trip: list frame -> option URL ->
#      hidden field -> refreshed list. The list frame writes its state into
#      data-list-filter-query; meeting_modal_controller merges it into the option's
#      URL when a project is chosen. The overview's project filter travels as
#      filter[project][], which does not collide with the nested route's own
#      project_id.
RSpec.describe 'Organisations::MeetingsOverview create', type: :request do
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
  let(:mixed_user) { user_with(project_a => 'read_write', project_b => 'read_only') }

  let(:overview_path) { organisation_meetings_path(organisation) }
  let(:anna) { MeetingParticipant.normalize_name('Anna Müller') }

  def new_form_path_for(project)
    "/projects/#{project.id}/meetings/new"
  end

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

  # The query the modal would put on the frame for this project.
  def new_url_query_for(project)
    option = Nokogiri::HTML(response.body).at_css("option[value='#{project.id}'][data-new-url]")
    return nil unless option

    Rack::Utils.parse_nested_query(URI.parse(option['data-new-url']).query)
  end

  def hidden_field_value(name)
    Nokogiri::HTML(response.body).at_css("input[type=hidden][name='#{name}']")&.[]('value')
  end

  describe 'the "+" and its project select' do
    it 'offers the modal to someone who may write meetings' do
      sign_in writer_a
      get overview_path

      expect(response.body).to include('meeting-modal')
      expect(response.body).to include(new_form_path_for(project_a))
    end

    it 'offers nothing at all to a reader who may not write anywhere' do
      sign_in reader_a
      get overview_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('meeting-modal')
      expect(response.body).not_to include(new_form_path_for(project_a))
    end

    it 'offers only the writable project when the user reads one and writes another' do
      project_b # the readable one must exist before the request
      sign_in mixed_user
      get overview_path

      expect(response.body).to include(new_form_path_for(project_a))
      expect(response.body).not_to include(new_form_path_for(project_b))
    end

    it 'leaves the list state out of the option URL: the modal reads it from the list' do
      sign_in writer_a
      get overview_path, params: { search: 'Kickoff', filter: { project: [project_a.id] } }

      # list_context says which list a save redraws; the list state is not in it.
      expect(new_url_query_for(project_a)).to eq('frame' => 'modal', 'list_context' => 'organisation')
      modal = Nokogiri::HTML(response.body).at_css('[data-controller="meeting-modal"]')
      expect(modal['data-meeting-modal-list-frame-value']).to eq('meetings_overview_results')
    end

    it 'writes the list state into the list frame, where the modal reads it' do
      create_meeting(project: project_a, title: 'Alpha Kickoff', creator: writer_a)
      sign_in writer_a
      get overview_path, params: { search: 'Kickoff', filter: { project: [project_a.id] }, filter_op: { project: 'or' } }

      state = Nokogiri::HTML(response.body).at_css('#meetings_overview_results [data-list-filter-query]')
      expect(Rack::Utils.parse_nested_query(state['data-list-filter-query']))
        .to eq('search' => 'Kickoff', 'filter' => { 'project' => [project_a.id] }, 'filter_op' => { 'project' => 'or' })
    end
  end

  describe 'GET new (frame: modal)' do
    it 'renders the form inside the modal frame for a writer' do
      sign_in writer_a
      get new_organisation_project_meeting_path(organisation, project_a, frame: 'modal', list_context: 'organisation'),
          headers: { 'Turbo-Frame' => 'meeting_modal_form' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('meeting_modal_form', 'meeting-form-card')
      # The save must be marked as coming from the overview, or it would answer into
      # frames this page does not have.
      expect(hidden_field_value('list_context')).to eq('organisation')
    end

    it 'refuses the form to a reader (the area gate), creating no way in' do
      sign_in reader_a
      get new_organisation_project_meeting_path(organisation, project_a, frame: 'modal'),
          headers: { 'Turbo-Frame' => 'meeting_modal_form' }

      expect(response).to have_http_status(:redirect)
      expect(response.body).not_to include('meeting-form-card')
    end

    it 'carries the list state into the form as hidden fields, by value' do
      # Second link. Asserting the field NAMES only would pass even if the values
      # were cross-wired or arrived empty, the regression this example is for.
      sign_in writer_a
      get new_organisation_project_meeting_path(organisation, project_a, frame: 'modal', list_context: 'organisation', search: 'Kickoff',
                                                                         filter: { participant: [anna], project: [project_b.id] }),
          headers: { 'Turbo-Frame' => 'meeting_modal_form' }

      expect(hidden_field_value('search')).to eq('Kickoff')
      expect(hidden_field_value('filter[participant][]')).to eq(anna)
      expect(hidden_field_value('filter[project][]')).to eq(project_b.id)
      expect(hidden_field_value('list_context')).to eq('organisation')
    end

    it 'falls back to the full page for an unknown frame value instead of half a page' do
      # The `case` added an implicit else: an unknown value delivers the whole
      # master-detail into a frame that matches nothing in it.
      sign_in writer_a
      get new_organisation_project_meeting_path(organisation, project_a, frame: 'bogus'),
          headers: { 'Turbo-Frame' => 'meeting_modal_form' }

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('id="meeting_modal_form"')
    end
  end

  describe 'POST create from the modal' do
    let(:valid_params) do
      { list_context: 'organisation', meeting: { title: 'Kickoff Alpha', occurred_at: Time.current } }
    end

    it 'creates the meeting and refreshes the org-wide list' do
      sign_in writer_a

      expect do
        post organisation_project_meetings_path(organisation, project_a), params: valid_params, as: :turbo_stream
      end.to change { ActsAsTenant.with_tenant(organisation) { Meeting.count } }.by(1)

      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(response.body).to include('meetings_overview_results')
      expect(response.body).to include('Kickoff Alpha')
      # The modal closes itself on success, so the flash is the only confirmation
      # left — asserted by its message, not by the bare word "flash", which the
      # stream's own target attribute already satisfies.
      expect(response.body).to include(I18n.t('flash.meetings.created'))
    end

    it 'leaves the results turbo-frame in place, so the page still works afterwards' do
      # `replace` swaps the TARGET ELEMENT. If the partial did not bring the frame,
      # the first save would delete it, and from then on the filter row would aim at
      # nothing and every later save would be dropped by Turbo without a word.
      sign_in writer_a

      2.times do |i|
        post organisation_project_meetings_path(organisation, project_a),
             params: valid_params.deep_merge(meeting: { title: "Kickoff #{i}" }), as: :turbo_stream

        expect(response.body).to include('<turbo-frame id="meetings_overview_results"')
      end

      expect(response.body).to include('Kickoff 0', 'Kickoff 1')
    end

    it 'does not answer into the project page list, which does not exist here, nor into the lane' do
      sign_in writer_a
      post organisation_project_meetings_path(organisation, project_a), params: valid_params, as: :turbo_stream

      # The rows name the lane they open in (list-row), so the stream targets
      # are asked, not the body: a save from the modal leaves the lane alone.
      expect(response.body).to include('target="meetings_overview_results"')
      expect(response.body).not_to include('target="meeting_display_frame"')
      expect(response.body).not_to include('target="meetings_results"')
    end

    it 'keeps an active participant filter in the refreshed list' do
      create_meeting(project: project_a, title: 'Alpha Kickoff', creator: writer_a, participants: ['Anna Müller'])
      create_meeting(project: project_a, title: 'Beta Sync', creator: writer_a, participants: ['Bert Berg'])
      sign_in writer_a

      post organisation_project_meetings_path(organisation, project_a),
           params: valid_params.merge(filter: { participant: [anna] }), as: :turbo_stream

      expect(response.body).to include('meetings_overview_results')
      expect(response.body).to include('Alpha Kickoff')
      expect(response.body).not_to include('Beta Sync')
    end

    it 'keeps an active project filter, which travels as filter[project][]' do
      # Third link. The save deliberately goes into a DIFFERENT project than the
      # filter names: reading params[:project_id] instead would silently pick up the
      # nested route's own parameter (the project being saved into) and look right.
      create_meeting(project: project_a, title: 'Alpha Kickoff', creator: writer_both)
      create_meeting(project: project_b, title: 'Beta Retro', creator: writer_both)
      sign_in writer_both

      post organisation_project_meetings_path(organisation, project_a),
           params: valid_params.merge(filter: { project: [project_b.id] }), as: :turbo_stream

      expect(response.body).to include('Beta Retro')
      expect(response.body).not_to include('Alpha Kickoff')
      # The saved meeting lives in project_a, which the filter excludes.
      expect(response.body).not_to include('Kickoff Alpha')
      expect(response.body).to include(I18n.t('flash.meetings.created_hidden_by_filter'))
    end

    it 'keeps an active saved view of the overview in the refreshed list' do
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

      expect(response.body).to include('Beta Retro', 'Kickoff Alpha')
      expect(response.body).to include(I18n.t('flash.meetings.created'))
    end

    it 'answers a filter of the wrong shape with a list, not a 500' do
      sign_in writer_a

      post organisation_project_meetings_path(organisation, project_a),
           params: valid_params.merge(filter: 'oops', sort: 'oops'), as: :turbo_stream

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('meetings_overview_results')
    end

    it 'keeps an active search in the refreshed list' do
      create_meeting(project: project_a, title: 'Alpha Kickoff', creator: writer_a)
      create_meeting(project: project_a, title: 'Beta Retro', creator: writer_a)
      sign_in writer_a

      post organisation_project_meetings_path(organisation, project_a),
           params: valid_params.merge(search: 'Retro'), as: :turbo_stream

      expect(response.body).to include('Beta Retro')
      expect(response.body).not_to include('Alpha Kickoff')
    end

    it 'says so when the active filter hides the meeting that was just saved' do
      # Otherwise the list re-renders as the "filter matched nothing" empty state
      # and a successful save reads as a failure.
      create_meeting(project: project_a, title: 'Alpha Kickoff', creator: writer_a, participants: ['Anna Müller'])
      sign_in writer_a

      post organisation_project_meetings_path(organisation, project_a),
           params: valid_params.merge(filter: { participant: [MeetingParticipant.normalize_name('Bert Berg')] }),
           as: :turbo_stream

      expect(response.body).to include(I18n.t('flash.meetings.created_hidden_by_filter'))
      expect(response.body).not_to include(I18n.t('flash.meetings.created'))
      expect(response.body).to include(I18n.t('views.organisations.meetings.index.empty_no_results'))
    end

    it 'answers 422 back into the modal frame on an invalid submit and creates nothing' do
      sign_in writer_a

      expect do
        post organisation_project_meetings_path(organisation, project_a),
             params: { list_context: 'organisation', meeting: { title: '', occurred_at: Time.current } },
             as: :turbo_stream
      end.not_to(change { ActsAsTenant.with_tenant(organisation) { Meeting.count } })

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('meeting_modal_form', 'meeting-form-card')
    end

    it 'denies the create to a reader and creates nothing' do
      sign_in reader_a

      expect do
        post organisation_project_meetings_path(organisation, project_a), params: valid_params, as: :turbo_stream
      end.not_to(change { ActsAsTenant.with_tenant(organisation) { Meeting.count } })

      # Without this a 500 on the denial path would pass the example.
      expect(response).to have_http_status(:redirect)
    end
  end

  describe 'pages of the refreshed list' do
    it 'point to the overview, not to the project the meeting went into' do
      2.times { |index| create_meeting(project: project_a, title: "Alt #{index}", creator: writer_a) }
      sign_in writer_a

      post organisation_project_meetings_path(organisation, project_a),
           params: { list_context: 'organisation', meeting: { title: 'Kickoff Alpha', occurred_at: Time.current }, items: 2 },
           as: :turbo_stream

      next_link = Nokogiri::HTML(response.body).at_css("a[title='#{I18n.t('views.shared.pagination_compact.next_page')}']")
      expect(next_link).to be_present
      expect(URI.parse(next_link['href']).path).to eq(overview_path)
      expect(Rack::Utils.parse_nested_query(URI.parse(next_link['href']).query)).to include('page' => '2', 'items' => '2')
    end
  end

  describe 'POST create from the modal without turbo (no JavaScript)' do
    it 'sends a successful save back to the overview it started from' do
      sign_in writer_a

      post organisation_project_meetings_path(organisation, project_a),
           params: { list_context: 'organisation', meeting: { title: 'Kickoff Alpha', occurred_at: Time.current } }

      expect(response).to redirect_to(organisation_meetings_path(organisation))
    end

    it 'keeps the list state on the way back' do
      sign_in writer_a

      post organisation_project_meetings_path(organisation, project_a),
           params: { list_context: 'organisation', meeting: { title: 'Kickoff Alpha', occurred_at: Time.current },
                     filter: { project: [project_a.id] }, sort: { column: 'title', direction: 'asc' } }

      expect(URI.parse(response.location).path).to eq(overview_path)
      expect(Rack::Utils.parse_nested_query(URI.parse(response.location).query))
        .to include('filter' => { 'project' => [project_a.id] }, 'sort' => { 'column' => 'title', 'direction' => 'asc' })
    end

    it 'renders the modal frame again on an invalid save' do
      sign_in writer_a

      post organisation_project_meetings_path(organisation, project_a),
           params: { list_context: 'organisation', meeting: { title: '', occurred_at: Time.current } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('meeting_modal_form', 'meeting-form-card')
    end
  end
end
