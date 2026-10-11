# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Saving assistant meeting analyses', type: :request do
  let(:organisation) { create(:organisation, assistant_enabled: true, ai_enabled: true) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:meeting) { create(:meeting, organisation: organisation, project: project, creator: user) }
  let(:chat) { create(:chat, organisation: organisation, user: user) }
  let(:citation) { Lalabase::Citations.meeting(meeting).stringify_keys }
  let(:answer) do
    create(:chatpost, chat: chat, role: :assistant, content: "## Entscheidungen\n\nStart im Mai. [1]",
                      model_used: 'test', source_citations: [citation],
                      analysis_context: { 'meeting_ids' => [meeting.id], 'instructions' => ['Nur verbindliche Entscheidungen.'],
                                          'provenance' => [citation] })
  end

  before do
    ActsAsTenant.current_tenant = organisation
    role = create(:role, organisation: organisation)
    create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
    create(:membership, organisation: organisation, user: user, role: role, active: true)
    create(:project_permission, project: project, user: user, meetings_access: 'read_write', notes_access: 'read_write')
    sign_in user
  end

  around do |example|
    ActsAsTenant.test_tenant = organisation
    example.run
  ensure
    ActsAsTenant.test_tenant = nil
  end

  def save_answer(**overrides)
    post organisation_assistant_chat_chatpost_analysis_path(organisation, chat, answer),
         params: { meeting_id: meeting.id, title: 'Verbindliche Entscheidungen', answer_key: answer.analysis_answer_key,
                   content: 'MANIPULIERT', is_private: false, include_in_search: true }.merge(overrides), as: :json
  end

  it 'copies exactly one completed answer privately without generating anything, with a working result link' do
    expect(ChatResponseJob).not_to receive(:perform_later)
    expect(Meetings::AnalysisJob).not_to receive(:perform_later)
    answer
    expect { save_answer }.to change(MeetingAnalysis, :count).by(1)
    expect(response).to have_http_status(:ok)
    analysis = MeetingAnalysis.last
    expect(analysis).to have_attributes(content: answer.content, is_private: true, include_in_search: false,
                                        creation_flag: false, creator_id: user.id, visible_to_user_id: user.id,
                                        prompt_snapshot: 'Nur verbindliche Entscheidungen.')
    expect(analysis.source_context['citations']).to eq([citation])
    expect(response.parsed_body['meeting_id']).to eq(meeting.id)
    url = response.parsed_body['url']
    get url
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(analysis.id, 'Verbindliche Entscheidungen')
  end

  it 'is idempotent across repeated requests and different titles or target choices' do
    save_answer
    expect { save_answer(title: 'Anderer Titel') }.not_to change(MeetingAnalysis, :count)
    expect(response).to have_http_status(:ok)
    expect(MeetingAnalysis.last.prompt_title).to eq('Verbindliche Entscheidungen')
    original_url = response.parsed_body['url']
    other = create(:meeting, project: project, creator: user)
    expect { save_answer(meeting_id: other.id) }.not_to change(MeetingAnalysis, :count)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['url']).to eq(original_url)
    expect(response.parsed_body['meeting_id']).to eq(meeting.id)
  end

  it 'keeps the original target after the conversation references change' do
    answer
    other = create(:meeting, project: project, creator: user)
    chat.update!(scope_references: [{ type: 'Meeting', id: other.id }])
    save_answer(meeting_id: other.id)
    expect(response).to have_http_status(:unprocessable_content)
    save_answer
    expect(MeetingAnalysis.last.meeting).to eq(meeting)
  end

  it 'requires an explicit choice among multiple supported meetings' do
    other = create(:meeting, project: project, creator: user)
    answer.update!(analysis_context: answer.analysis_context.merge('meeting_ids' => [meeting.id, other.id],
                                                                   'provenance' => [citation, Lalabase::Citations.meeting(other).stringify_keys]))
    save_answer(meeting_id: '')
    expect(response).to have_http_status(:unprocessable_content)
    save_answer(meeting_id: other.id)
    expect(MeetingAnalysis.last.meeting).to eq(other)
  end

  it 'leaves validation failures retryable' do
    save_answer(title: '')
    expect(response).to have_http_status(:unprocessable_content)
    expect(MeetingAnalysis.count).to eq(0)
    save_answer(title: 'Korrigiert')
    expect(response).to have_http_status(:ok)
  end

  [nil, ''].each do |model|
    it "rejects pending/failed responses (#{model.inspect})" do
      answer.update!(model_used: model)
      expect { save_answer }.not_to change(MeetingAnalysis, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  it 'rejects user messages, unknown provenance and unassociated answers' do
    answer.update!(role: :user)
    save_answer
    expect(response).to have_http_status(:unprocessable_content)
    answer.update!(role: :assistant, analysis_context: nil)
    save_answer
    expect(response).to have_http_status(:unprocessable_content)
  end

  it 'rejects a stale answer key after regeneration' do
    key = answer.analysis_answer_key
    answer.update!(content: 'Neue Antwort')
    save_answer(answer_key: key)
    expect(response).to have_http_status(:unprocessable_content)
    expect(MeetingAnalysis.count).to eq(0)
  end

  it 'does not let a later answer mutate an existing analysis' do
    save_answer
    original = MeetingAnalysis.last.content
    answer.update!(content: 'Überarbeitet')
    expect(MeetingAnalysis.last.content).to eq(original)
    expect { save_answer }.to change(MeetingAnalysis, :count).by(1)
  end

  it 'rejects another owner’s chat and a substituted response from another chat' do
    foreign = create(:chat, organisation: organisation, user: create(:user))
    post organisation_assistant_chat_chatpost_analysis_path(organisation, foreign, answer), params: {}, as: :json
    expect(response).to have_http_status(:not_found)
    sign_in user
    unrelated = create(:chat, organisation: organisation, user: user)
    post organisation_assistant_chat_chatpost_analysis_path(organisation, unrelated, answer), params: { meeting_id: meeting.id, title: 'Valid title', answer_key: answer.analysis_answer_key }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end

  it 'rejects a foreign organisation meeting even if its id is injected in the snapshot' do
    foreign_org = create(:organisation)
    foreign_meeting = ActsAsTenant.with_tenant(foreign_org) { create(:meeting) }
    answer.update!(analysis_context: answer.analysis_context.merge('meeting_ids' => [foreign_meeting.id]))
    save_answer(meeting_id: foreign_meeting.id)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it 'rechecks meeting write rights and all sources, including model-declared unused sources' do
    answer
    permission = ProjectPermission.find_by!(project: project, user: user)
    permission.update!(meetings_access: 'read_only')
    save_answer
    expect(response).to have_http_status(:unprocessable_content)
    permission.update!(meetings_access: 'read_write')
    note = create(:note, project: project, organisation: organisation)
    provenance = [citation, Lalabase::Citations.note(note).stringify_keys.merge('used' => false)]
    answer.update!(analysis_context: answer.analysis_context.merge('provenance' => provenance))
    permission.update!(notes_access: 'no_access')
    save_answer
    expect(response).to have_http_status(:unprocessable_content)
    expect(MeetingAnalysis.count).to eq(0)
  end

  it 'allows the existing publication and separate search release for a meeting-only answer' do
    save_answer
    analysis = MeetingAnalysis.last
    path = organisation_project_meeting_analysis_path(organisation, project, meeting, analysis)
    patch path, params: { meeting_analysis: { is_private: false } }
    expect(analysis.reload).to have_attributes(is_private: false, include_in_search: false)
    patch path, params: { meeting_analysis: { include_in_search: true } }
    expect(analysis.reload.include_in_search).to be true
  end

  it 'keeps mixed sources private and refuses both publication and rerunning through the old actor' do
    note = create(:note, project: project, organisation: organisation)
    answer.update!(analysis_context: answer.analysis_context.merge('provenance' => [citation, Lalabase::Citations.note(note).stringify_keys]))
    save_answer
    analysis = MeetingAnalysis.last
    expect(analysis).to be_present
    result = Actors::SaveMeetingAnalysis.call(meeting: meeting, current_user: user, id: analysis.id, params: { is_private: false, include_in_search: true })
    expect(result).not_to be_success
    expect(analysis.reload).to have_attributes(is_private: true, include_in_search: false)
    expect(Meetings::AnalysisJob).not_to receive(:perform_later)
    result = Actors::SaveMeetingAnalysis.call(meeting: meeting, current_user: user, id: analysis.id, params: { rerun: true })
    expect(result).not_to be_success
  end

  it 'renders a conversation with several eligible answers' do
    Prosopite.pause
    answer
    3.times do
      create(:chatpost, chat: chat, role: :assistant, content: 'Überarbeitet', model_used: 'test',
                        source_citations: answer.source_citations, analysis_context: answer.analysis_context)
    end
    Prosopite.resume
    get organisation_assistant_panel_path(organisation, chat_id: chat.id)
    expect(response).to have_http_status(:ok)
    expect(response.body.scan('Als Analyse speichern').size).to eq(4)
  end

  it 'uses the existing prompt library with the existing meeting read/write permissions' do
    prompt = create(:analysis_prompt, organisation: organisation, creator: user)
    path = organisation_assistant_analysis_prompts_path(organisation)
    get path, params: { meeting_id: meeting.id }, as: :json
    expect(response.parsed_body['prompts'].pluck('id')).to include(prompt.id)
    expect(response.parsed_body['manage_url']).to eq(
      organisation_project_meeting_path(organisation, project, meeting, anchor: "analyses_meeting_#{meeting.id}")
    )
    post path, params: { meeting_id: meeting.id, analysis_prompt: { title: 'Neu', prompt_text: 'Mein angepasster Auftrag' } }, as: :json
    expect(response).to have_http_status(:created)
    expect(AnalysisPrompt.find_by!(title: 'Neu').prompt_text).to eq('Mein angepasster Auftrag')
    expect do
      delete path, params: { meeting_id: meeting.id, prompt_id: prompt.id }, as: :json
    end.to change(AnalysisPrompt, :count).by(-1)
    expect(response.parsed_body['message']).to eq(I18n.t('assistant_analysis.template_deleted'))
    ProjectPermission.find_by!(project: project, user: user).update!(meetings_access: 'read_only')
    get path, params: { meeting_id: meeting.id }, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.media_type).to eq('application/json')
    expect do
      post path, params: { meeting_id: meeting.id, analysis_prompt: { title: 'Verboten', prompt_text: 'Auftrag' } }, as: :json
    end.not_to change(AnalysisPrompt, :count)
    expect do
      delete path, params: { meeting_id: meeting.id, prompt_id: AnalysisPrompt.find_by!(title: 'Neu').id }, as: :json
    end.not_to change(AnalysisPrompt, :count)
    expect(response).to have_http_status(:forbidden)
  end

  it 'does not delete a prompt from another organisation' do
    foreign_organisation = create(:organisation)
    foreign_prompt = ActsAsTenant.with_tenant(foreign_organisation) do
      create(:analysis_prompt, organisation: foreign_organisation)
    end

    expect do
      delete organisation_assistant_analysis_prompts_path(organisation),
             params: { meeting_id: meeting.id, prompt_id: foreign_prompt.id }, as: :json
    end.not_to change(AnalysisPrompt, :count)

    expect(response).to have_http_status(:not_found)
    expect(response.media_type).to eq('application/json')
    expect(AnalysisPrompt.unscoped.find(foreign_prompt.id)).to eq(foreign_prompt)
  end

  it 'returns JSON for missing meetings and forbids prompt access without assistant permission' do
    path = organisation_assistant_analysis_prompts_path(organisation)
    get path, params: { meeting_id: SecureRandom.uuid }, as: :json
    expect(response).to have_http_status(:not_found)
    expect(response.media_type).to eq('application/json')
    Permission.where(category: 'assistant', action: 'use_assistant').update_all(allowed: false)
    get path, params: { meeting_id: meeting.id }, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.media_type).to eq('application/json')
    expect do
      post path, params: { meeting_id: meeting.id, analysis_prompt: { title: 'Denied', prompt_text: 'Prompt' } }, as: :json
    end.not_to change(AnalysisPrompt, :count)
    expect(response).to have_http_status(:forbidden)
  end

  it 'rejects saving at the HTTP boundary before invoking its actor when assistant access is revoked' do
    answer
    Permission.where(category: 'assistant', action: 'use_assistant').update_all(allowed: false)
    expect(Actors::SaveAssistantAnalysis).not_to receive(:call)
    save_answer
    expect(response).to have_http_status(:forbidden)
    expect(response.media_type).to eq('application/json')
  end

  it 'renders the persisted success and original destination after reload' do
    save_answer
    url = response.parsed_body['url']
    get organisation_assistant_panel_path(organisation, chat_id: chat.id)
    document = Nokogiri::HTML(response.body)
    saved = document.at_css("#save_analysis_#{answer.analysis_answer_key}")
    expect(saved.at_css('details').key?('hidden')).to be true
    expect(saved.at_css('[data-assistant-analysis-target="success"]')['hidden']).to be_nil
    expect(saved.at_css('[data-assistant-analysis-target="link"]')['href']).to eq(url)
  end
end
