# frozen_string_literal: true

require 'rails_helper'

# "Neues Meeting" on "Alle Meetings": what the project select in the lane may
# name, and what its form may write (doc meetings_uebersicht_vereinheitlichen_plan.md,
# PR 4). The select offers the projects where the person may WRITE meetings, and
# nothing else, not even the name of a project they may only read. The form
# behind it is the project-nested MeetingsController#new and #create, whose own
# gates decide; list_context=organisation chooses the list a save redraws, never
# what anyone may write.
#
# Every negative assertion first proves the page or the select is there, so a
# redirect or a 404 cannot pass it in a vacuum.
RSpec.describe 'Organisations::MeetingsOverview new meeting access', :ci_guard, type: :request do
  before { Prosopite.pause } # several requests and setup writes per example
  after { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:project_a) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Alpha') } }
  let(:project_b) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Lesbar') } }
  let(:project_c) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Verborgen') } }
  let(:overview_path) { organisation_meetings_path(organisation) }
  let(:lane_frame) { { 'Turbo-Frame' => 'meeting_display_frame' } }

  def member_with(levels)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      levels.each { |project, level| create(:project_permission, user: user, project: project, meetings_access: level) }
    end
    user
  end

  def page_body = Capybara.string(response.body)

  def select_options
    page_body.all('#meeting-new-project option', visible: :all).map { |option| option.text.strip }
  end

  def meeting_count
    ActsAsTenant.with_tenant(organisation) { Meeting.count }
  end

  # Writes in Alpha, reads Lesbar, and has nothing at all in Verborgen.
  let(:mixed_user) { member_with(project_a => 'read_write', project_b => 'read_only') }
  let(:reader) { member_with(project_a => 'read_only') }

  before do
    project_c
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting, project: project_b, organisation: organisation, title: 'Lesbar Kickoff')
    end
  end

  describe 'the project select in the lane' do
    before { sign_in mixed_user }

    it 'names only the projects the person may write meetings in, on a full visit' do
      get overview_path, params: { new: 'meeting' }

      expect(response).to have_http_status(:ok)
      expect(page_body).to have_css('#meeting_display_frame #meeting-new-project')
      expect(select_options).to include('Projekt Alpha')
      expect(select_options).not_to include('Projekt Lesbar', 'Projekt Verborgen')
      # Readable, so the list and its filter bar may name it; the lane may not.
      expect(page_body).to have_css('#meetings_overview_results', text: 'Lesbar Kickoff')
      expect(page_body.find('#meeting_display_frame')).to have_no_text('Projekt Lesbar')
      expect(response.body).not_to include('Projekt Verborgen')
    end

    it 'names only the projects the person may write meetings in, in the lane frame' do
      get overview_path, params: { new: 'meeting', frame: 'content', frame_id: 'meeting_display_frame' }, headers: lane_frame

      expect(response).to have_http_status(:ok)
      expect(page_body).to have_css('turbo-frame#meeting_display_frame #meeting-new-project')
      expect(select_options).to include('Projekt Alpha')
      expect(response.body).not_to include('Projekt Lesbar', 'Projekt Verborgen')
    end

    it 'leads every option to the form of its own project and nowhere else' do
      get overview_path, params: { new: 'meeting' }

      urls = page_body.all('#meeting-new-project option[data-form-url]', visible: :all).map { |option| option['data-form-url'] }
      expect(urls.size).to eq(1)
      expect(URI.parse(urls.first).path).to eq(new_organisation_project_meeting_path(organisation, project_a))
    end
  end

  describe 'without the right to write meetings anywhere' do
    before { sign_in reader }

    it 'shows the list and opens nothing on a full visit with ?new=meeting' do
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project_a, organisation: organisation, title: 'Alpha Kickoff')
      end
      get overview_path, params: { new: 'meeting' }

      expect(response).to have_http_status(:ok)
      expect(page_body).to have_css('#meetings_overview_results', text: 'Alpha Kickoff')
      expect(page_body).to have_css('turbo-frame#meeting_display_frame')
      expect(page_body).to have_no_css('#meeting-new-project')
      expect(page_body).to have_no_css('.labor-layout-view.show-content')
      expect(page_body).to have_no_css("a[title='#{I18n.t('views.organisations.meetings_overview.index.new_meeting')}']")
    end

    it 'answers the lane frame with no select' do
      get overview_path, params: { new: 'meeting', frame: 'content', frame_id: 'meeting_display_frame' }, headers: lane_frame

      expect(response.body).not_to include('meeting-new-project')
      expect(response.body).not_to include('Projekt Alpha')
    end

    # A right taken away while the page stays open: the "+" still stands there.
    # The shared refusal redirected back to the overview, fetch kept the
    # Turbo-Frame header, and the redirected request was refused again, until
    # the browser gave up on too many redirects. The refusal answers in the frame.
    it 'refuses the lane frame inside the frame, with a message and no redirect' do
      get overview_path, params: { new: 'meeting' }, headers: lane_frame.merge('Referer' => "http://www.example.com#{overview_path}")

      expect(response).to have_http_status(:forbidden)
      expect(response.location).to be_nil
      expect(page_body).to have_css('turbo-frame#meeting_display_frame',
                                    text: I18n.t('views.organisations.meetings_overview.new_meeting.denied'))
      expect(page_body).to have_css('turbo-frame#meeting_display_frame [data-lane-close]')
      expect(page_body).to have_no_css('#meeting-new-project')
    end

    it 'answers a lane frame request without new=meeting with the empty lane, not the refusal of the select' do
      get overview_path, headers: lane_frame.merge('Referer' => "http://www.example.com#{overview_path}")

      expect(response).to have_http_status(:ok)
      expect(response.location).to be_nil
      expect(page_body).to have_css('turbo-frame#meeting_display_frame',
                                    text: I18n.t('views.organisations.meetings.index.select_meeting_hint'))
      expect(page_body).to have_no_text(I18n.t('views.organisations.meetings_overview.new_meeting.denied'))
    end
  end

  # The last right to read meetings went while the page stayed open. The page
  # gate redirected every request, and the frames of the page (the lane after
  # the "+", the list after a filter) got the start page without their frame:
  # Turbo replaced the frame with "Content missing" and threw. A full visit goes
  # to the start page with a message, so a frame asks Turbo for a full visit of
  # the same address (turbo-visit-control reload), which then takes that way.
  describe 'after the last right to read meetings went' do
    let(:nobody) { member_with({}) }

    before { sign_in nobody }

    it 'sends a full visit to the start page with a message (the positive control)' do
      get overview_path, params: { new: 'meeting' }

      expect(response).to redirect_to(organisation_root_path(organisation_id: organisation.id))
      expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))
    end

    {
      'the lane' => Organisations::MeetingsController::DETAIL_FRAME_ID,
      'the list' => Organisations::MeetingsController::OVERVIEW_LIST_FRAME_ID,
      'the sentence of the bar' => "#{Organisations::MeetingsController::OVERVIEW_LIST_FRAME_ID}_sentence"
    }.each do |name, frame_id|
      it "asks Turbo for a full visit from #{name}, without a redirect and without a meeting" do
        get overview_path, params: { new: 'meeting' }, headers: { 'Turbo-Frame' => frame_id }

        # 200, not 403: Turbo reloads only for a successful answer.
        expect(response).to have_http_status(:ok)
        expect(response.location).to be_nil
        expect(page_body).to have_css('meta[name="turbo-visit-control"][content="reload"]', visible: :all)
        expect(page_body).to have_no_css('turbo-frame')
        expect(response.body).not_to include('Lesbar Kickoff')
      end
    end
  end

  # A lane request to this address without new=meeting comes from a redirect:
  # a lane action MeetingsController refused (Pundit leads back to the Referer)
  # or could not finish (a meeting deleted meanwhile), and fetch keeps the
  # Turbo-Frame header. The lane then shows what a full visit of that address
  # shows there. Until the review of PR 4 it said "you may create meetings in
  # no project", with 403, to someone who writes in Alpha.
  describe 'a lane request without new=meeting' do
    let(:lesbar_meeting) { ActsAsTenant.with_tenant(organisation) { Meeting.find_by!(title: 'Lesbar Kickoff') } }
    let(:denied) { I18n.t('views.organisations.meetings_overview.new_meeting.denied') }

    before { sign_in mixed_user }

    it 'shows the meeting a refused action in the lane leads back to' do
      referer = "http://www.example.com#{organisation_meetings_path(organisation, meeting_id: lesbar_meeting.id)}"
      post toggle_search_organisation_project_meeting_path(organisation, project_b, lesbar_meeting),
           params: { create_embeddings: '0', list_context: 'organisation' },
           headers: lane_frame.merge('Referer' => referer, 'Accept' => 'text/vnd.turbo-stream.html, text/html')
      expect(response).to redirect_to(referer)

      follow_redirect!(headers: lane_frame)

      expect(response).to have_http_status(:ok)
      expect(page_body).to have_css('turbo-frame#meeting_display_frame h2', text: 'Lesbar Kickoff')
      expect(page_body).to have_no_text(denied)
      expect(page_body).to have_no_css('#meeting-new-project')
    end

    it 'shows the empty lane for a meeting it cannot open, and nothing of it' do
      hidden = ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project_c, organisation: organisation, title: 'Verborgen Kickoff')
      end
      get overview_path, params: { meeting_id: hidden.id }, headers: lane_frame

      expect(response).to have_http_status(:ok)
      expect(page_body).to have_css('turbo-frame#meeting_display_frame',
                                    text: I18n.t('views.organisations.meetings.index.select_meeting_hint'))
      expect(response.body).not_to include('Verborgen Kickoff', 'Projekt Verborgen')
      expect(page_body).to have_no_text(denied)
    end

    it 'keeps the select for new=meeting, which is what the "+" asks for' do
      get overview_path, params: { new: 'meeting' }, headers: lane_frame

      expect(response).to have_http_status(:ok)
      expect(page_body).to have_css('turbo-frame#meeting_display_frame #meeting-new-project')
    end
  end

  describe 'the form behind the select (MeetingsController#new, frame: content)' do
    def get_form(project)
      get new_organisation_project_meeting_path(organisation, project, frame: 'content', frame_id: 'meeting_new_form',
                                                                       list_context: 'organisation'),
          headers: { 'Turbo-Frame' => 'meeting_new_form' }
    end

    it 'renders the form for a writable project (the positive control)' do
      sign_in mixed_user
      get_form(project_a)

      expect(response).to have_http_status(:ok)
      expect(page_body).to have_css('turbo-frame#meeting_new_form #meeting-form-card form')
    end

    it 'renders no form for a project the person may only read' do
      sign_in mixed_user
      get_form(project_b)

      expect(response).to have_http_status(:redirect)
      expect(response.body).not_to include('meeting-form-card')
    end

    it 'renders no form for a project the person may not read at all' do
      sign_in mixed_user
      get_form(project_c)

      expect(response).to have_http_status(:redirect)
      expect(response.body).not_to include('meeting-form-card')
    end

    it 'renders no form for a project of another organisation' do
      other = create(:organisation)
      foreign = ActsAsTenant.with_tenant(other) { create(:project, organisation: other, name: 'Fremdprojekt') }
      sign_in mixed_user
      get_form(foreign)

      expect(response.status).to be_in([302, 403, 404])
      expect(response.body).not_to include('meeting-form-card', 'Fremdprojekt')
    end
  end

  describe 'a save into a project the select would not offer' do
    let(:params) { { list_context: 'organisation', frame_id: 'meeting_new_form', meeting: { title: 'Untergeschoben', occurred_at: Time.current } } }

    it 'saves into a writable project (the positive control)' do
      sign_in mixed_user

      expect do
        post organisation_project_meetings_path(organisation, project_a), params: params, as: :turbo_stream
      end.to change { meeting_count }.by(1)
    end

    it 'refuses a project the person may only read, with the context, and creates nothing' do
      sign_in mixed_user

      expect do
        post organisation_project_meetings_path(organisation, project_b), params: params, as: :turbo_stream
      end.not_to(change { meeting_count })
      expect(response).to have_http_status(:redirect)
      expect(response.body).not_to include('meetings_overview_results')
    end

    it 'refuses a project the person may not read, with the context, and creates nothing' do
      sign_in mixed_user

      expect do
        post organisation_project_meetings_path(organisation, project_c), params: params, as: :turbo_stream
      end.not_to(change { meeting_count })
      expect(response).to have_http_status(:redirect)
    end

    it 'refuses a project of another organisation, with the context, and creates nothing' do
      other = create(:organisation)
      foreign = ActsAsTenant.with_tenant(other) { create(:project, organisation: other) }
      sign_in mixed_user

      expect do
        post organisation_project_meetings_path(organisation, foreign), params: params, as: :turbo_stream
      end.not_to(change { Meeting.unscoped.count })
      expect(response.status).to be_in([302, 403, 404])
    end
  end
end
