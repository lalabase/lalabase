# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Assistant::AnalysisRevision do
  let(:organisation) { create(:organisation, assistant_enabled: true) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:meeting) { create(:meeting, organisation: organisation, project: project, creator: user) }
  let(:chat) { create(:chat, organisation: organisation, user: user, scope_references: [{ type: 'Meeting', id: meeting.id }]) }
  let(:answer) do
    create(:chatpost, chat: chat, role: :assistant, model_used: 'test', content: 'Selected answer. [1]',
                      source_citations: [Lalabase::Citations.meeting(meeting)],
                      analysis_context: { meeting_ids: [meeting.id], instructions: ['Analyse.'],
                                          provenance: [Lalabase::Citations.meeting(meeting)] })
  end
  let(:params) { { content: 'Mach das bitte kürzer.', revision_answer_id: answer.id, revision_answer_key: answer.analysis_answer_key } }

  before do
    ActsAsTenant.current_tenant = organisation
    role = create(:role, organisation: organisation)
    create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
    create(:membership, organisation: organisation, user: user, role: role, active: true)
    create(:project_permission, project: project, user: user, meetings_access: 'read_write')
  end
  after { ActsAsTenant.current_tenant = nil }

  def submit(overrides = {})
    Actors::CreateChatpost.call(chat: chat, current_user: user, params: params.merge(overrides))
  end

  it 'stores the explicit answer id and key beside the final instruction, without saving an analysis' do
    answer
    result = nil
    expect { result = submit }.not_to change(MeetingAnalysis, :count)
    expect(result).to be_success
    expect(result.resource.analysis_context).to include('revision_answer_id' => answer.id, 'revision_answer_key' => answer.analysis_answer_key,
                                                        'instruction' => 'Mach das bitte kürzer.')
    expect(described_class.call(chat: chat, user: user, context: result.resource.analysis_context)).to eq(answer)
  end

  it 'rejects a changed answer between selecting and submitting it' do
    old_key = answer.analysis_answer_key
    answer.update!(content: 'Regenerated content')
    expect(ChatResponseJob).not_to receive(:perform_later)
    result = submit(revision_answer_key: old_key)
    expect(result).not_to be_success
    expect(result.resource.errors[:base]).to be_present
    expect(result.resource.analysis_context['revision_answer_id']).to eq(answer.id)
    expect(result.resource.content).to eq(params[:content])
  end

  it 'rejects another owned conversation, even with the valid answer key' do
    another = create(:chat, organisation: organisation, user: user)
    other_answer = create(:chatpost, chat: another, role: :assistant, model_used: 'test', content: answer.content,
                                     analysis_context: answer.analysis_context, source_citations: answer.source_citations)
    expect(ChatResponseJob).not_to receive(:perform_later)
    expect(submit(revision_answer_id: other_answer.id, revision_answer_key: other_answer.analysis_answer_key)).not_to be_success
  end

  it 'rechecks ownership, source access and completion before allowing the revision' do
    context = params.stringify_keys
    expect(described_class.call(chat: chat, user: create(:user), context: context)).to be_nil
    ProjectPermission.find_by!(user: user, project: project).update!(meetings_access: 'no_access')
    expect(submit).not_to be_success
    ProjectPermission.find_by!(user: user, project: project).update!(meetings_access: 'read_write')
    answer.update!(model_used: nil)
    expect(submit).not_to be_success
  end

  it 'keeps rendering cheap but rechecks all source permissions at the write boundary' do
    answer
    expect(Assistant::AnalysisSources).not_to receive(:readable?)
    eligibility = Assistant::AnalysisEligibility.new(answer: answer, user: user)
    expect(eligibility.available?).to be true
    expect(eligibility.meetings).to eq([meeting])
  end

  it 'shares the owner gate between rendering and the saving actor' do
    intruder = create(:user)
    role = create(:admin_role, organisation: organisation)
    create(:membership, organisation: organisation, user: intruder, role: role, active: true)
    expect(Assistant::AnalysisEligibility.new(answer: answer, user: intruder).available?).to be false
    result = Actors::SaveAssistantAnalysis.call(chat: chat, answer_id: answer.id, answer_key: answer.analysis_answer_key,
                                                meeting_id: meeting.id, title: 'Stolen', current_user: intruder)
    expect(result).not_to be_success
    expect(MeetingAnalysis.count).to eq(0)
  end
end
