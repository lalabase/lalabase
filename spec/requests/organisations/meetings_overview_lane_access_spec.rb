# frozen_string_literal: true

require 'rails_helper'

# "Alle Meetings" with the lane: what the lane may reveal
# (doc/meetings_uebersicht_vereinheitlichen_plan.md, PR 3). A meeting_id from
# the address resolves through policy_scope(Meeting) only, the detail stays
# behind the project's own gates, and list_context chooses which list a save
# redraws, never what anyone may read or write.
#
# Every negative assertion first proves the page rendered with the thing it is
# about (the list, a row), so a redirect or a 404 cannot pass it in a vacuum.
RSpec.describe 'Organisations::MeetingsOverview lane access', :ci_guard, type: :request do
  before { Prosopite.pause } # several requests and setup writes per example
  after { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:project_a) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Alpha') } }
  let(:project_b) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Beta') } }
  let(:overview_path) { organisation_meetings_path(organisation) }

  def member_with(levels)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      levels.each { |project, level| create(:project_permission, user: user, project: project, meetings_access: level) }
    end
    user
  end

  def create_meeting(org:, project:, title:)
    ActsAsTenant.with_tenant(org) { create(:meeting, project: project, organisation: org, title: title) }
  end

  def page_body = Capybara.string(response.body)

  def row_titles
    page_body.all('#meetings_overview_results tr[data-meeting-id] h5').map { |title| title.text.strip }
  end

  let(:reader_a) { member_with(project_a => 'read_only') }
  let!(:alpha) { create_meeting(org: organisation, project: project_a, title: 'Alpha Kickoff') }
  let!(:beta) { create_meeting(org: organisation, project: project_b, title: 'Beta Geheim') }

  describe 'opening by address (?meeting_id=)' do
    before { sign_in reader_a }

    it 'opens a readable meeting (the positive control)' do
      get overview_path, params: { meeting_id: alpha.id }

      expect(page_body).to have_css('#meeting_display_frame h2', text: 'Alpha Kickoff')
    end

    it 'opens nothing for a meeting in a project the reader may not read' do
      get overview_path, params: { meeting_id: beta.id }

      expect(response).to have_http_status(:ok)
      expect(row_titles).to eq(['Alpha Kickoff'])
      expect(page_body).to have_css('turbo-frame#meeting_display_frame')
      expect(page_body).to have_no_css('#meeting_display_frame h2')
      expect(page_body).to have_no_css('.labor-layout-view.show-content')
      expect(response.body).not_to include('Beta Geheim')
    end

    it 'opens nothing for a meeting of another organisation' do
      other = create(:organisation)
      other_project = ActsAsTenant.with_tenant(other) { create(:project, organisation: other) }
      foreign = create_meeting(org: other, project: other_project, title: 'Fremd Vertraulich')

      get overview_path, params: { meeting_id: foreign.id }

      expect(response).to have_http_status(:ok)
      expect(row_titles).to eq(['Alpha Kickoff'])
      expect(page_body).to have_no_css('#meeting_display_frame h2')
      expect(response.body).not_to include('Fremd Vertraulich')
    end

    it 'opens nothing for an unknown id or one that is not a string' do
      get overview_path, params: { meeting_id: SecureRandom.uuid }

      expect(response).to have_http_status(:ok)
      expect(row_titles).to eq(['Alpha Kickoff'])
      expect(page_body).to have_no_css('#meeting_display_frame h2')

      get "#{overview_path}?meeting_id[]=#{alpha.id}"

      expect(response).to have_http_status(:ok)
      expect(row_titles).to eq(['Alpha Kickoff'])
      expect(page_body).to have_no_css('#meeting_display_frame h2')
    end
  end

  describe 'the detail address a row loads (frame: content)' do
    before { sign_in reader_a }

    it 'renders a readable meeting (the positive control)' do
      get organisation_project_meeting_path(organisation, project_a, alpha, frame: 'content', list_context: 'organisation'),
          headers: { 'Turbo-Frame' => 'meeting_display_frame' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Alpha Kickoff')
    end

    it 'refuses a meeting in a project the reader may not read, with the context too' do
      get organisation_project_meeting_path(organisation, project_b, beta, frame: 'content', list_context: 'organisation'),
          headers: { 'Turbo-Frame' => 'meeting_display_frame' }

      expect(response).to have_http_status(:redirect)
      expect(response.body).not_to include('Beta Geheim')
    end

    it 'does not find a meeting through another project the reader may read' do
      get organisation_project_meeting_path(organisation, project_a, beta, frame: 'content', list_context: 'organisation'),
          headers: { 'Turbo-Frame' => 'meeting_display_frame' }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'a save from the lane without the right to write' do
    def update_alpha(**context)
      patch organisation_project_meeting_path(organisation, project_a, alpha, format: :turbo_stream),
            params: { meeting: { title: 'Überschrieben' }, frame_id: 'meeting_display_frame' }.merge(context)
    end

    it 'is refused exactly as without the context, and changes nothing' do
      sign_in reader_a

      update_alpha
      without_context = [response.status, response.location]
      update_alpha(list_context: 'organisation')

      expect(without_context.first).to eq(302)
      expect([response.status, response.location]).to eq(without_context)
      expect(response.body).not_to include('meetings_overview_results')
      expect(alpha.reload.title).to eq('Alpha Kickoff')
    end

    it 'refuses a delete and a search release flip with the context too' do
      sign_in reader_a

      delete organisation_project_meeting_path(organisation, project_a, alpha, format: :turbo_stream, list_context: 'organisation')
      expect(response).to have_http_status(:redirect)
      expect(Meeting.unscoped.exists?(alpha.id)).to be(true)

      post toggle_search_organisation_project_meeting_path(organisation, project_a, alpha, format: :turbo_stream),
           params: { create_embeddings: '1', list_context: 'organisation' }
      expect(response.body).not_to include('meetings_overview_results')
      expect(alpha.reload.create_embeddings).to be(false)
    end
  end

  describe 'a forged list_context' do
    let(:writer) { member_with(project_a => 'read_write', project_b => 'read_write') }

    before { sign_in writer }

    ['org', 'Organisation', ' organisation', ['organisation'], { 'search' => 'x' }].each do |forged|
      it "redraws the project list for #{forged.inspect}" do
        patch organisation_project_meeting_path(organisation, project_a, alpha, format: :turbo_stream),
              params: { meeting: { title: 'Alpha neu' }, frame_id: 'meeting_display_frame', list_context: forged }

        expect(response).to have_http_status(:ok)
        targets = page_body.all("turbo-stream[action='replace']").map { |stream| stream['target'] }
        expect(targets).to include('meetings_results')
        expect(targets).not_to include('meetings_overview_results')
        # The project list of project A: B's meeting is not in it.
        expect(response.body).not_to include('Beta Geheim')
      end
    end

    it 'never widens the list beyond the readable projects with the real value' do
      reader = member_with(project_a => 'read_write')
      sign_in reader

      patch organisation_project_meeting_path(organisation, project_a, alpha, format: :turbo_stream),
            params: { meeting: { title: 'Alpha neu' }, frame_id: 'meeting_display_frame', list_context: 'organisation' }

      expect(response).to have_http_status(:ok)
      # Capybara does not walk a <template>: the list is read from the raw body.
      list = response.body[%r{<turbo-stream action="replace" target="meetings_overview_results"><template>(.*?)</template>}m, 1]
      titles = Capybara.string(list.to_s).all('tr[data-meeting-id] h5').map { |title| title.text.strip }
      expect(titles).to eq(['Alpha neu'])
      expect(response.body).not_to include('Beta Geheim')
    end
  end
end
