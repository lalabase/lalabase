# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatResponseJob, type: :job do
  let(:organisation) { create(:organisation, assistant_enabled: true) }
  let(:user) { create(:user) }
  let(:meeting) { create(:meeting, organisation: organisation, creator: user) }
  let(:chat) { create(:chat, organisation: organisation, user: user, scope_references: [{ type: 'Meeting', id: meeting.id }]) }
  let(:provider) { double('provider') }
  let(:job) { described_class.new }

  before do
    ActsAsTenant.current_tenant = organisation
    allow(job).to receive(:detect_and_lock_language)
    allow(job).to receive(:resolve_provider).and_return(provider)
    allow(job).to receive(:retrieve_rag_context).and_return(nil)
    allow(job).to receive(:track_ai_usage)
  end

  def respond_with(content, citations)
    runner = instance_double(Lalabase::Tools::Runner, citations: citations, tool_calls_log: [])
    allow(Lalabase::Tools::Runner).to receive(:new).and_return(runner)
    allow(runner).to receive(:call) do |&block|
      block.call(content)
      { model_used: 'test', token_usage: {} }
    end
    job.perform(chat, acting_user_id: user.id, question_chatpost_id: chat.chatposts.not_assistant.order(:created_at).last.id)
    chat.chatposts.assistant.order(:created_at).last
  end

  it 'serializes all response and regeneration jobs for the same chat' do
    normal = described_class.new(chat, acting_user_id: user.id)
    regeneration = described_class.new(chat, regenerate_chatpost_id: SecureRandom.uuid, acting_user_id: user.id)
    expect(normal.concurrency_key).to eq(regeneration.concurrency_key)
    expect(normal.concurrency_key).not_to eq(described_class.new(build_stubbed(:chat)).concurrency_key)
    expect(described_class.concurrency_limit).to eq(1)
    expect(described_class.concurrency_on_conflict).to eq(:block)
  end

  it 'snapshots new and existing chat submissions, and keeps normal answers and revisions in the chat' do
    result = Actors::SaveChat.call(current_user: user,
                                   reference_keys: ["Meeting:#{meeting.id}"],
                                   params: { organisation: organisation, chatposts_attributes: [{ content: 'Analysiere die Entscheidungen.' }] })
    # No meeting reach here: grant it explicitly before trying the draft write again.
    expect(result).not_to be_success
    role = create(:admin_role, organisation: organisation)
    create(:membership, organisation: organisation, user: user, role: role, active: true)
    result = Actors::SaveChat.call(current_user: user,
                                   reference_keys: ["Meeting:#{meeting.id}"],
                                   params: { organisation: organisation, chatposts_attributes: [{ content: 'Analysiere die Entscheidungen.' }] })
    expect(result).to be_success
    initial = result.resource.chatposts.first
    expect(initial.analysis_context['references']).to eq([{ 'type' => 'Meeting', 'id' => meeting.id }])

    Actors::CreateChatpost.call(chat: chat, current_user: user, params: { content: 'Analysiere die Entscheidungen.' })
    citation = Lalabase::Citations.meeting(meeting)
    answer = nil
    expect { answer = respond_with('Start im Mai. [1]', [citation]) }.not_to change(MeetingAnalysis, :count)
    expect(answer.analysis_context['meeting_ids']).to eq([meeting.id])
    expect(answer.analysis_context['instructions']).to eq(['Analysiere die Entscheidungen.'])
    answer.update!(source_coverage: { searched: 1, total: 3, outside: true })
    Actors::CreateChatpost.call(chat: chat, current_user: user, params: { content: 'Kürzer.', revision_answer_id: answer.id, revision_answer_key: answer.analysis_answer_key })
    expect(job).not_to receive(:retrieve_rag_context)
    revised = nil
    expect { revised = respond_with('Start: Mai. [1]', []) }.not_to change(MeetingAnalysis, :count)
    expect(revised.analysis_context['instructions']).to eq(['Analysiere die Entscheidungen.', 'Kürzer.'])
    expect(revised.analysis_context['meeting_ids']).to eq([meeting.id])
    expect(revised.source_citations).to eq(answer.source_citations)
    expect(revised.source_coverage).to eq(answer.source_coverage)
  end

  it 'retains unread reference metadata and the selected project as provenance through a revision' do
    role = create(:admin_role, organisation: organisation)
    create(:membership, organisation: organisation, user: user, role: role, active: true)
    note = create(:note, organisation: organisation, project: meeting.project, title: 'Restricted plan')
    chat.update!(scope_project: meeting.project, scope_references: [{ type: 'Meeting', id: meeting.id }, { type: 'Note', id: note.id }])
    Actors::CreateChatpost.call(chat: chat, current_user: user, params: { content: 'Analysiere die Entscheidungen.' })
    answer = respond_with('Entscheidung zu Restricted plan. [1]', [Lalabase::Citations.meeting(meeting)])
    expect(answer.analysis_context['provenance']).to include(
      { 'type' => 'note', 'id' => note.id, 'project_id' => note.project_id },
      { 'type' => 'project', 'id' => meeting.project_id }
    )
    expect(Assistant::AnalysisSources.publishable?(context: answer.analysis_context, meeting: meeting)).to be false
    chat.update!(scope_references: [{ type: 'Meeting', id: meeting.id }])
    Actors::CreateChatpost.call(chat: chat, current_user: user, params: { content: 'Bitte kürzer.', revision_answer_id: answer.id, revision_answer_key: answer.analysis_answer_key })
    revised = respond_with('Restricted plan. [1]', [])
    expect(revised.analysis_context['meeting_ids']).to eq([meeting.id])
    expect(revised.analysis_context['provenance']).to include('type' => 'note', 'id' => note.id, 'project_id' => note.project_id)
  end
  it 'answers each queued question once and sends a user turn last to the provider' do
    first = Actors::CreateChatpost.call(chat: chat, current_user: user, params: { content: 'First queued question' }).resource
    second = Actors::CreateChatpost.call(chat: chat, current_user: user, params: { content: 'Second queued question' }).resource
    captured = []
    allow(job).to receive(:generate_answer) do |_chat, message, _provider, messages, *_rest|
      captured << messages.last
      message.update!(content: "Answer to #{messages.last[:content]}", model_used: 'test')
    end
    job.perform(chat, question_chatpost_id: first.id)
    job.perform(chat, question_chatpost_id: second.id)
    expect(captured).to eq([{ role: 'user', content: first.content }, { role: 'user', content: second.content }])
    expect(chat.chatposts.assistant.order(:created_at).pluck(:content)).to eq(['Answer to First queued question', 'Answer to Second queued question'])
  end

  it 'does not generate a new paid answer for a deleted regeneration target or question' do
    expect(job).not_to receive(:resolve_provider)
    expect { job.perform(chat, regenerate_chatpost_id: SecureRandom.uuid) }.not_to(change { chat.chatposts.count })
    expect { job.perform(chat, question_chatpost_id: SecureRandom.uuid) }.not_to(change { chat.chatposts.count })
  end

  ['Nur eine Frage: …', 'Nur kurz: …', 'Add the tickets from …', 'Ergänzend …', 'Mach das bitte kürzer.'].each do |content|
    it "runs retrieval for an ordinary message saying #{content}" do
      create(:chatpost, chat: chat, role: :assistant, model_used: 'test', content: 'Previous analysis',
                        analysis_context: { meeting_ids: [meeting.id], instructions: ['Analyse.'], provenance: [] })
      question = Actors::CreateChatpost.call(chat: chat, current_user: user, params: { content: content }).resource
      allow(job).to receive(:generate_answer)
      job.perform(chat, question_chatpost_id: question.id)
      expect(job).to have_received(:retrieve_rag_context)
    end
  end

  it 'revises the selected older answer rather than the most recent one and rechecks a queued revision' do
    role = create(:admin_role, organisation: organisation)
    create(:membership, organisation: organisation, user: user, role: role, active: true)
    Actors::CreateChatpost.call(chat: chat, current_user: user, params: { content: 'Analyse.' })
    selected = respond_with('Selected older answer. [1]', [Lalabase::Citations.meeting(meeting)])
    create(:chatpost, chat: chat, role: :assistant, content: 'Unrelated later answer', model_used: 'test')
    question = Actors::CreateChatpost.call(chat: chat, current_user: user,
                                           params: { content: 'Mach das bitte kürzer.', revision_answer_id: selected.id,
                                                     revision_answer_key: selected.analysis_answer_key }).resource
    captured = nil
    allow(job).to receive(:generate_answer) { |_chat, _message, _provider, messages, *_rest| captured = messages }
    job.perform(chat, question_chatpost_id: question.id)
    expect(captured.last(2)).to eq([{ role: 'assistant', content: selected.content }, { role: 'user', content: question.content }])
    expect(captured.map { |message| message[:content] }).not_to include('Unrelated later answer')
    selected.update!(content: 'Changed while waiting')
    expect(job).not_to receive(:resolve_provider)
    expect { job.perform(chat, question_chatpost_id: question.id) }.to change { chat.chatposts.count }.by(1)
    error = chat.chatposts.assistant.order(:created_at).last
    expect(error).to have_attributes(content: I18n.t('assistant_analysis.revision_unavailable', locale: chat.language.presence || I18n.locale),
                                     model_used: nil, analysis_context: { 'provenance' => [] })
  end
  it 'clears completion metadata if an error occurs after the final content write' do
    answer = create(:chatpost, chat: chat, role: :assistant, model_used: 'test', content: 'Finished',
                               analysis_context: { meeting_ids: [meeting.id], instructions: ['Analyse.'], provenance: [] })
    job.send(:update_or_create_error, chat, answer, 'Provider error')
    expect(answer.reload).to have_attributes(model_used: nil, analysis_context: { 'provenance' => [] }, source_citations: [])
    expect(answer).not_to be_savable_meeting_answer
  end

  it 'replays an interrupted stream but blocks saving and publishing its unverifiable successor' do
    role = create(:admin_role, organisation: organisation)
    create(:membership, organisation: organisation, user: user, role: role, active: true)
    partial = create(:chatpost, chat: chat, role: :assistant, content: 'Secret from an interrupted tool run',
                                model_used: nil, analysis_context: nil)
    Actors::CreateChatpost.call(chat: chat, current_user: user, params: { content: 'Analysiere das Meeting.' })
    expect(job).to receive(:build_messages).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs).tap do |messages|
        expect(messages).to include(role: 'assistant', content: partial.content)
      end
    end
    answer = respond_with('Analyse mit unvollständiger Herkunft. [1]', [Lalabase::Citations.meeting(meeting)])
    expect(answer.analysis_context['provenance']).to include('type' => 'unverified_history')
    expect(Assistant::AnalysisSources.publishable?(context: answer.analysis_context, meeting: meeting)).to be false
    result = nil
    expect do
      result = Actors::SaveAssistantAnalysis.call(chat: chat, answer_id: answer.id, meeting_id: meeting.id,
                                                  title: 'Analyse', current_user: user, answer_key: answer.analysis_answer_key)
    end.not_to change(MeetingAnalysis, :count)
    expect(result).not_to be_success
  end

  %i[existing_placeholder before_placeholder unavailable_provider].each do |failure|
    it "keeps later analyses savable after the known error path #{failure}" do
      role = create(:admin_role, organisation: organisation)
      create(:membership, organisation: organisation, user: user, role: role, active: true)
      placeholder = create(:chatpost, chat: chat, role: :assistant, content: 'Partial output') unless failure == :before_placeholder
      if failure == :unavailable_provider
        job.send(:mark_service_unavailable, placeholder, chat)
      else
        job.send(:update_or_create_error, chat, placeholder, 'Known provider error')
      end
      error = chat.chatposts.assistant.order(:created_at).last
      expect(error).to have_attributes(model_used: nil, analysis_context: { 'provenance' => [] })
      expect(error).not_to be_savable_meeting_answer
      Actors::CreateChatpost.call(chat: chat, current_user: user, params: { content: 'Analysiere das Meeting.' })
      answer = respond_with('Entscheidungen. [1]', [Lalabase::Citations.meeting(meeting)])
      expect(answer.analysis_context['provenance']).not_to include('type' => 'unverified_history')
      result = Actors::SaveAssistantAnalysis.call(chat: chat, answer_id: answer.id, meeting_id: meeting.id,
                                                  title: 'Analyse', current_user: user, answer_key: answer.analysis_answer_key)
      expect(result).to be_success
    end
  end

  it 'includes the revision instruction chain in the history budget while retaining the current question' do
    role = create(:admin_role, organisation: organisation)
    create(:membership, organisation: organisation, user: user, role: role, active: true)
    Actors::CreateChatpost.call(chat: chat, current_user: user, params: { content: 'Analyse.' })
    selected = respond_with('Selected answer. [1]', [Lalabase::Citations.meeting(meeting)])
    budget = described_class::MAX_CONTEXT_TOKENS * described_class::CONTEXT_CHARS_PER_TOKEN
    selected.analysis_context['instructions'] = ['Analyse.'] + Array.new(100) { 'Long instruction ' * 40 }
    selected.save!
    question = Actors::CreateChatpost.call(chat: chat, current_user: user,
                                           params: { content: 'Kürzer.', revision_answer_id: selected.id,
                                                     revision_answer_key: selected.analysis_answer_key }).resource
    expect(job).to receive(:generate_answer) do |_chat, _message, _provider, messages, *_rest|
      expect(messages.drop(1).sum { |message| message[:content].length }).to be <= budget
      expect(messages.last).to eq(role: 'user', content: question.content)
      expect(messages).to include(role: 'assistant', content: selected.content)
    end
    job.perform(chat, question_chatpost_id: question.id)
  end

  %i[deleted_source changed_source revoked_access deleted_question].each do |failure|
    it "reports an unavailable regeneration after #{failure} without altering the previous result" do
      role = create(:admin_role, organisation: organisation)
      membership = create(:membership, organisation: organisation, user: user, role: role, active: true)
      Actors::CreateChatpost.call(chat: chat, current_user: user, params: { content: 'Analyse.' })
      selected = respond_with('Selected answer. [1]', [Lalabase::Citations.meeting(meeting)])
      question = Actors::CreateChatpost.call(chat: chat, current_user: user,
                                             params: { content: 'Kürzer.', revision_answer_id: selected.id,
                                                       revision_answer_key: selected.analysis_answer_key }).resource
      revised = respond_with('Shorter answer. [1]', [])
      snapshot = revised.attributes
      case failure
      when :deleted_source then selected.destroy!
      when :changed_source then selected.update!(content: 'Changed')
      when :revoked_access then membership.update!(active: false)
      when :deleted_question then question.destroy!
      end
      expect(job).not_to receive(:resolve_provider)
      expect do
        job.perform(chat, regenerate_chatpost_id: revised.id, acting_user_id: user.id)
      end.to change { chat.chatposts.assistant.count }.by(1)
      expect(revised.reload.attributes).to eq(snapshot)
      error = chat.chatposts.assistant.order(:created_at).last
      expect(error).to have_attributes(content: I18n.t('assistant_analysis.revision_unavailable', locale: chat.language.presence || I18n.locale),
                                       model_used: nil, analysis_context: { 'provenance' => [] })
      expect(error).not_to be_savable_meeting_answer
    end
  end

  it 'rejects an oversized revision instead of inheriting a target omitted from the provider history' do
    role = create(:admin_role, organisation: organisation)
    create(:membership, organisation: organisation, user: user, role: role, active: true)
    Actors::CreateChatpost.call(chat: chat, current_user: user, params: { content: 'Analyse.' })
    selected = respond_with('Selected answer. [1]', [Lalabase::Citations.meeting(meeting)])
    budget = described_class::MAX_CONTEXT_TOKENS * described_class::CONTEXT_CHARS_PER_TOKEN
    question = Actors::CreateChatpost.call(chat: chat, current_user: user,
                                           params: { content: 'x' * budget, revision_answer_id: selected.id,
                                                     revision_answer_key: selected.analysis_answer_key }).resource
    expect(job).not_to receive(:resolve_provider)
    expect { job.perform(chat, question_chatpost_id: question.id) }.to change { chat.chatposts.assistant.count }.by(1)
    error = chat.chatposts.assistant.order(:created_at).last
    expect(error).to have_attributes(content: I18n.t('assistant_analysis.revision_too_long', locale: chat.language.presence || I18n.locale),
                                     model_used: nil, analysis_context: { 'provenance' => [] })
    expect(error).not_to be_savable_meeting_answer
  end
end
