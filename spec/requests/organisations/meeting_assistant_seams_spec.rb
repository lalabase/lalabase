# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Meeting assistant seams', type: :request do
  let(:assistant_enabled) { true }
  let(:organisation) do
    create(:organisation, assistant_enabled: assistant_enabled, ai_enabled: true,
                          ai_provider: 'openai', ai_access_token: 'sk-org-own-1234567890abcdef')
  end
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:meeting) { create(:meeting, organisation: organisation, project: project, creator: user, title: 'Planungsrunde', notes: 'Start im Mai') }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    sign_in user
  end
  after { ActsAsTenant.current_tenant = nil }

  def html = Nokogiri::HTML.fragment(response.body)

  def expect_seams
    expect(response).to have_http_status(:ok)
    markers = html.css('[data-assistant-context]')
    expect(markers.size).to eq(1)
    expect(markers.first['data-assistant-context']).to eq(meeting.id)
    expect(markers.first['data-assistant-context-type']).to eq('Meeting')
    expect(markers.first['data-assistant-context-label']).to eq("#{I18n.l(meeting.occurred_at.to_date)} · Planungsrunde")
    button = html.at_css('[data-assistant-trigger-type-value="Meeting"]')
    expect(button['data-assistant-trigger-id-value']).to eq(meeting.id)
    expect(button['data-controller']).to eq('assistant-trigger')
    expect(button['class']).to include('inline-flex')
  end

  it 'renders the common seams and the two explicit desktop entries without an analyses lane' do
    get organisation_project_meetings_path(organisation, project, meeting_id: meeting.id)

    expect_seams
    expect(html.at_css('#assistant_panel')).to be_present
    expect(html.at_css('#meeting_analyses_lane')).to be_nil
    expect(html.at_css('[data-assistant-trigger-intent-value="analysis"]')).to be_present
    expect(html.at_css('[data-assistant-trigger-intent-value="ticket-suggestions"]')).to be_present
    expect(response.body).not_to include("action=\"#{organisation_project_meeting_analyses_path(organisation, project, meeting)}\"")
  end

  it 'renders the same seams after loading a meeting detail frame' do
    get organisation_project_meeting_path(organisation, project, meeting, frame: 'content', frame_id: 'meeting_display_frame'),
        headers: { 'Turbo-Frame' => 'meeting_display_frame' }

    expect_seams
    expect(html.at_css('#meeting_display_frame')).to be_present
  end

  it 'uses the same assistant entries on mobile without the old inline form' do
    get organisation_project_meetings_path(organisation, project, meeting_id: meeting.id, viewport: 'mobile')

    expect_seams
    expect(html.at_css('#meeting_analyses_lane')).to be_nil
    expect(html.at_css("form[action='#{organisation_project_meeting_analyses_path(organisation, project, meeting)}']")).to be_nil
    expect(html.at_css('[data-assistant-trigger-intent-value="analysis"]')).to be_present
    expect(html.at_css('[data-assistant-trigger-intent-value="ticket-suggestions"]')).to be_present
  end

  it 'does not offer an object from an empty detail' do
    get organisation_project_meetings_path(organisation, project)

    expect(html.css('[data-assistant-context], [data-assistant-trigger-type-value]')).to be_empty
  end

  context 'with the assistant disabled' do
    let(:assistant_enabled) { false }

    it 'omits assistant seams and does not bring back the analyses lane' do
      get organisation_project_meetings_path(organisation, project, meeting_id: meeting.id)

      expect(html.css('[data-assistant-context], [data-assistant-trigger-type-value]')).to be_empty
      expect(html.at_css('#meeting_analyses_lane')).to be_nil
    end

    # Rollout decision A: no entry, but never silent. Both AI sections tell a writer in
    # an AI org that creation moved to an assistant they do not have.
    it 'says in both AI sections that creation moved to the assistant' do
      get organisation_project_meetings_path(organisation, project, meeting_id: meeting.id)

      expect(html.at_css("#analyses_meeting_#{meeting.id}").text)
        .to include(I18n.t('views.organisations.meetings.analyses.assistant_not_enabled'))
      expect(html.at_css("#ticket_suggestions_meeting_#{meeting.id}").text)
        .to include(I18n.t('views.organisations.meetings.ticket_suggestions.assistant_not_enabled'))
    end
  end

  context 'with meeting read permission only' do
    let(:role) { create(:role, organisation: organisation) }

    it 'offers the assistant without requiring write permission' do
      create(:project_permission, user: user, project: project, meetings_access: 'read_only')
      get organisation_project_meetings_path(organisation, project, meeting_id: meeting.id)

      expect_seams
      expect(html.css("a[title='#{I18n.t('views.organisations.meetings.show.edit_meeting')}']")).to be_empty
      expect(html.css('[data-assistant-trigger-intent-value]')).to be_empty
    end
  end
end
