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
#   3. The three filters must survive the whole round trip: page -> option URL ->
#      hidden field -> refreshed list. Each link is asserted here; the middle one is
#      where the overview's `project_id` becomes `overview_project_id`, because that
#      name is taken by the nested route.
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

    it 'writes the active filters into every option URL, project_id renamed' do
      # First link of the round trip. Only this assertion can catch the rename:
      # the page's `project_id` has to leave as `overview_project_id`, or it would
      # retarget the nested route instead of filtering the list.
      sign_in writer_a
      get overview_path, params: { search: 'Kickoff', participant: anna, project_id: project_a.id }

      query = new_url_query_for(project_a)
      expect(query).to include('frame' => 'modal', 'search' => 'Kickoff', 'participant' => anna,
                               'overview_project_id' => project_a.id)
      expect(query).not_to have_key('project_id')
    end

    it 'survives a non-scalar project_id in the address instead of 500ing' do
      create_meeting(project: project_a, title: 'Alpha Kickoff', creator: writer_a)
      sign_in writer_a

      get overview_path, params: { project_id: { 'a' => '1' } }

      expect(response).to have_http_status(:ok)
    end

    it 'leaves the filter parameters out of the option URL when nothing is filtered' do
      sign_in writer_a
      get overview_path

      expect(new_url_query_for(project_a)).to eq('frame' => 'modal')
    end
  end

  describe 'GET new (frame: modal)' do
    it 'renders the form inside the modal frame for a writer' do
      sign_in writer_a
      get new_organisation_project_meeting_path(organisation, project_a, frame: 'modal'),
          headers: { 'Turbo-Frame' => 'meeting_modal_form' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('meeting_modal_form', 'meeting-form-card')
      # The save must be marked as coming from the overview, or it would answer into
      # frames this page does not have.
      expect(response.body).to include('overview_modal')
    end

    it 'refuses the form to a reader (the area gate), creating no way in' do
      sign_in reader_a
      get new_organisation_project_meeting_path(organisation, project_a, frame: 'modal'),
          headers: { 'Turbo-Frame' => 'meeting_modal_form' }

      expect(response).to have_http_status(:redirect)
      expect(response.body).not_to include('meeting-form-card')
    end

    it 'carries the active list filters into the form as hidden fields, by value' do
      # Second link. Asserting the field NAMES only would pass even if the three
      # were cross-wired or arrived empty — the regression this example is for.
      sign_in writer_a
      get new_organisation_project_meeting_path(organisation, project_a, frame: 'modal',
                                                                         search: 'Kickoff', participant: anna,
                                                                         overview_project_id: project_b.id),
          headers: { 'Turbo-Frame' => 'meeting_modal_form' }

      expect(hidden_field_value('search')).to eq('Kickoff')
      expect(hidden_field_value('participant')).to eq(anna)
      expect(hidden_field_value('overview_project_id')).to eq(project_b.id)
      expect(hidden_field_value('context')).to eq('overview_modal')
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
      { context: 'overview_modal', meeting: { title: 'Kickoff Alpha', occurred_at: Time.current } }
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

    it 'does not answer into the project page frames, which do not exist here' do
      sign_in writer_a
      post organisation_project_meetings_path(organisation, project_a), params: valid_params, as: :turbo_stream

      expect(response.body).not_to include('meeting_display_frame')
      expect(response.body).not_to include('target="meetings_results"')
    end

    it 'keeps an active participant filter in the refreshed list' do
      create_meeting(project: project_a, title: 'Alpha Kickoff', creator: writer_a, participants: ['Anna Müller'])
      create_meeting(project: project_a, title: 'Beta Sync', creator: writer_a, participants: ['Bert Berg'])
      sign_in writer_a

      post organisation_project_meetings_path(organisation, project_a),
           params: valid_params.merge(participant: anna), as: :turbo_stream

      expect(response.body).to include('meetings_overview_results')
      expect(response.body).to include('Alpha Kickoff')
      expect(response.body).not_to include('Beta Sync')
    end

    it 'keeps an active project filter, which travels as overview_project_id' do
      # Third link, and the only place the rename is observable end to end. The save
      # deliberately goes into a DIFFERENT project than the filter names: reading
      # params[:project_id] instead would silently pick up the nested route's own
      # parameter (the project being saved into) and look right anyway.
      create_meeting(project: project_a, title: 'Alpha Kickoff', creator: writer_both)
      create_meeting(project: project_b, title: 'Beta Retro', creator: writer_both)
      sign_in writer_both

      post organisation_project_meetings_path(organisation, project_a),
           params: valid_params.merge(overview_project_id: project_b.id), as: :turbo_stream

      expect(response.body).to include('Beta Retro')
      expect(response.body).not_to include('Alpha Kickoff')
      # The saved meeting lives in project_a, which the filter excludes.
      expect(response.body).not_to include('Kickoff Alpha')
    end

    it 'answers a non-scalar overview_project_id with a filtered list, not a 500' do
      # search and participant both coerce; this one reached `where` untouched, where
      # a nested parameter is read as a condition on a table called project_id.
      sign_in writer_a

      post organisation_project_meetings_path(organisation, project_a),
           params: valid_params.merge(overview_project_id: { 'a' => '1' }), as: :turbo_stream

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
           params: valid_params.merge(participant: MeetingParticipant.normalize_name('Bert Berg')),
           as: :turbo_stream

      expect(response.body).to include(I18n.t('flash.meetings.created_hidden_by_filter'))
      expect(response.body).not_to include(I18n.t('flash.meetings.created'))
      expect(response.body).to include(I18n.t('views.organisations.meetings_overview.index.empty_no_results'))
    end

    it 'answers 422 back into the modal frame on an invalid submit and creates nothing' do
      sign_in writer_a

      expect do
        post organisation_project_meetings_path(organisation, project_a),
             params: { context: 'overview_modal', meeting: { title: '', occurred_at: Time.current } },
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

  describe 'POST create from the modal without turbo (no JavaScript)' do
    it 'sends a successful save back to the overview it started from' do
      sign_in writer_a

      post organisation_project_meetings_path(organisation, project_a),
           params: { context: 'overview_modal', meeting: { title: 'Kickoff Alpha', occurred_at: Time.current } }

      expect(response).to redirect_to(organisation_meetings_path(organisation))
    end

    it 'renders the modal frame again on an invalid save' do
      sign_in writer_a

      post organisation_project_meetings_path(organisation, project_a),
           params: { context: 'overview_modal', meeting: { title: '', occurred_at: Time.current } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('meeting_modal_form', 'meeting-form-card')
    end
  end
end
