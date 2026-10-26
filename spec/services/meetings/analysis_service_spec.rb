# frozen_string_literal: true

require 'rails_helper'

# Meetings::AnalysisService — the async analysis generator for a MeetingAnalysis.
#
# Intent: prove the SOURCE rule (transcript preferred, notes fallback — via
# meeting.summary_source), prove the prompt is built from the frozen snapshot + the
# source RAW (no squish), prove usage is metered with the meeting_analysis action
# and the analysis subject, and prove every gate/LLM failure maps to a readable
# creation_error while the pending flag is ALWAYS cleared. LLM stubbed at the Factory.
#
# S1b (doc/ki_provider_reichweite_plan.md): the pin to OpenAI + gpt-4o-mini is
# gone — this path follows the ORG's chat provider now. The seam moved from
# Factory.build to Factory.for_feature(:meeting_analysis, org) — the SAME
# registry row the controller gates on. The routing itself is pinned by the
# shared example at the bottom (which deliberately does NOT stub the Factory).
# Stubs here are key-scoped on purpose: a blanket receive(:for_feature) would
# answer for a sibling's key too, and all three meetings rows resolve alike.
RSpec.describe Meetings::AnalysisService do
  let(:organisation) { create(:organisation, ai_enabled: true) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user, organisation: organisation) }

  let(:transcript) { nil }
  let(:notes) { nil }
  let(:meeting) do
    create(:meeting, organisation: organisation, project: project, creator: user,
                     transcript: transcript, notes: notes)
  end
  let(:analysis) do
    # content starts empty, mirroring the real pending state the actor creates.
    create(:meeting_analysis, meeting: meeting, creator: user, creation_flag: true,
                              content: '', prompt_snapshot: 'PROMPT_ANWEISUNG_XYZ')
  end

  let(:provider) { double('llm_provider') }
  let(:chat_result) do
    { content: 'Analyse-Ergebnis.', token_usage: { total_tokens: 60 }, model_used: 'gpt-4o-mini' }
  end

  before do
    ActsAsTenant.current_tenant = organisation
    allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:meeting_analysis, organisation).and_return(provider)
    allow(provider).to receive(:chat).and_return(chat_result)
    allow(Lalabase::Llm::UsageTracking).to receive(:record)
  end

  after { ActsAsTenant.current_tenant = nil }

  # Capture the text actually handed to the LLM.
  def prompt_sent
    messages = nil
    allow(provider).to receive(:chat) do |**kwargs|
      messages = kwargs[:messages]
      chat_result
    end
    described_class.call(analysis: analysis)
    messages.first[:content]
  end

  describe 'source selection (transcript preferred, notes fallback)' do
    context 'with a transcript AND notes' do
      let(:transcript) { 'VERBATIM_TRANSCRIPT_XYZ' }
      let(:notes) { 'CURATED_NOTES_ABC' }

      it 'analyses the transcript, not the notes' do
        text = prompt_sent
        expect(text).to include('VERBATIM_TRANSCRIPT_XYZ')
        expect(text).not_to include('CURATED_NOTES_ABC')
      end
    end

    context 'with notes but no transcript' do
      let(:notes) { 'CURATED_NOTES_ABC' }

      it 'analyses the notes' do
        expect(prompt_sent).to include('CURATED_NOTES_ABC')
      end
    end
  end

  describe 'prompt construction (snapshot + source RAW)' do
    let(:transcript) { "Anna: Wir starten mit Q3.\nBert: Einverstanden." }

    it 'includes the frozen prompt snapshot verbatim' do
      expect(prompt_sent).to include('PROMPT_ANWEISUNG_XYZ')
    end

    it 'preserves the speaker-turn newlines in the source (no squish)' do
      expect(prompt_sent).to include("Anna: Wir starten mit Q3.\nBert: Einverstanden.")
    end

    context 'with an oversized source' do
      let(:transcript) { "K#{'a' * (Meetings::BaseLlmService::SOURCE_CHAR_LIMIT + 5_000)}" }

      it 'caps the source and marks the truncation' do
        text = prompt_sent
        expect(text.length).to be < Meetings::BaseLlmService::SOURCE_CHAR_LIMIT + 1_000
        expect(text).to include('gekürzt')
      end
    end
  end

  describe 'success' do
    let(:transcript) { 'Some transcript' }

    it 'persists the content and clears the flag and error' do
      described_class.call(analysis: analysis)
      analysis.reload
      expect(analysis.content).to eq('Analyse-Ergebnis.')
      expect(analysis.creation_flag).to be(false)
      expect(analysis.creation_error).to eq('')
    end

    it 'meters usage with the meeting_analysis action and the analysis subject' do
      expect(Lalabase::Llm::UsageTracking).to receive(:record).with(
        hash_including(organisation: organisation, provider: provider, call_type: 'meeting_analysis',
                       action: Lalabase::Llm::ActionRegistry::MEETING_ANALYSIS, subject: analysis)
      )
      described_class.call(analysis: analysis)
    end
  end

  describe 'empty LLM result' do
    let(:transcript) { 'Some transcript' }
    let(:chat_result) { { content: '  ', token_usage: {}, model_used: 'gpt-4o-mini' } }

    it 'records the empty-result error and clears the flag' do
      described_class.call(analysis: analysis)
      analysis.reload
      expect(analysis.content).to eq('')
      expect(analysis.creation_flag).to be(false)
      expect(analysis.creation_error).to eq(I18n.t('services.meetings.analysis.empty_result'))
    end
  end

  # An answer that hit the output limit is cut mid-way. It used to be stored as a
  # finished analysis without a hint; now it is a readable error and nothing of
  # it is kept. The call still cost tokens, so it is metered all the same.
  describe 'answer cut at the output limit (stop_reason length)' do
    let(:transcript) { 'Some transcript' }
    let(:chat_result) do
      { content: 'Analyse, die mitten im', stop_reason: 'length', model_used: 'gpt-4o-mini',
        token_usage: { input_tokens: 900, output_tokens: 1500, total_tokens: 2400 } }
    end

    it 'records the truncated error, keeps no part of the answer and clears the flag' do
      described_class.call(analysis: analysis)
      analysis.reload
      expect(analysis.content).to eq('')
      expect(analysis.creation_flag).to be(false)
      expect(analysis.creation_error).to eq(I18n.t('services.meetings.analysis.truncated'))
    end

    it 'leaves an earlier content untouched' do
      analysis.update!(content: 'FRUEHERE_ANALYSE')
      described_class.call(analysis: analysis)
      expect(analysis.reload.content).to eq('FRUEHERE_ANALYSE')
    end

    it 'still meters the call' do
      described_class.call(analysis: analysis)
      expect(Lalabase::Llm::UsageTracking).to have_received(:record).with(hash_including(subject: analysis))
    end

    it 'logs the token counts but not the answer' do
      logged = []
      allow(Rails.logger).to receive(:warn) { |message| logged << message }
      described_class.call(analysis: analysis)
      expect(logged.join).to include('2400').and include('1500')
      expect(logged.join).not_to include('mitten im')
    end
  end

  describe 'answer cut before any text (provider raises TruncatedError)' do
    let(:transcript) { 'Some transcript' }
    let(:cut_result) do
      { content: '', stop_reason: 'length', model_used: 'gemini-2.5-flash',
        token_usage: { input_tokens: 900, output_tokens: 0, total_tokens: 3548 } }
    end

    before do
      allow(provider).to receive(:chat)
        .and_raise(Lalabase::Llm::Provider::TruncatedError.new('empty content', result: cut_result))
    end

    it 'records the truncated error (not the generic one) and meters the billed call' do
      described_class.call(analysis: analysis)
      analysis.reload
      expect(analysis.creation_error).to eq(I18n.t('services.meetings.analysis.truncated'))
      expect(analysis.creation_flag).to be(false)
      expect(analysis.content).to eq('')
      expect(Lalabase::Llm::UsageTracking).to have_received(:record)
        .with(hash_including(token_usage: cut_result[:token_usage], subject: analysis))
    end
  end

  describe 'an answer that ended normally (stop_reason stop)' do
    let(:transcript) { 'Some transcript' }
    let(:chat_result) { { content: 'Fertige Analyse.', stop_reason: 'stop', token_usage: {}, model_used: 'gpt-4o-mini' } }

    it 'is stored as before' do
      described_class.call(analysis: analysis)
      expect(analysis.reload.content).to eq('Fertige Analyse.')
      expect(analysis.creation_error).to eq('')
    end
  end

  describe 'blank source' do
    it 'does not call the LLM and clears the pending flag' do
      expect(Lalabase::Llm::Factory).not_to receive(:for_feature)
      described_class.call(analysis: analysis)
      analysis.reload
      expect(analysis.creation_flag).to be(false)
      expect(analysis.content).to eq('')
    end
  end

  describe 'error mapping (flag always cleared, no raise)' do
    let(:transcript) { 'Some transcript' }

    {
      'Lalabase::Llm::Factory::MissingCredentialError' => 'not_configured',
      'Lalabase::Llm::Provider::AuthError' => 'invalid_key'
    }.each do |error_class, key|
      context "when the provider raises #{error_class}" do
        before { allow(provider).to receive(:chat).and_raise(error_class.constantize) }

        it "maps to the #{key} message and clears the flag" do
          expect { described_class.call(analysis: analysis) }.not_to raise_error
          analysis.reload
          expect(analysis.creation_error).to eq(I18n.t("services.meetings.analysis.#{key}"))
          expect(analysis.creation_flag).to be(false)
        end
      end
    end

    context 'when the gate raises QuotaExceededError' do
      before { allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:meeting_analysis, organisation).and_raise(Lalabase::Llm::QuotaExceededError) }

      it 'maps to the quota-exhausted message and clears the flag' do
        described_class.call(analysis: analysis)
        analysis.reload
        expect(analysis.creation_error).to eq(I18n.t('services.meetings.analysis.quota_exhausted'))
        expect(analysis.creation_flag).to be(false)
      end
    end

    context 'when an unexpected StandardError is raised' do
      before { allow(provider).to receive(:chat).and_raise(StandardError, 'boom') }

      it 'maps to the generic error and clears the flag' do
        expect { described_class.call(analysis: analysis) }.not_to raise_error
        analysis.reload
        expect(analysis.creation_error).to eq(I18n.t('services.meetings.analysis.generic_error'))
        expect(analysis.creation_flag).to be(false)
      end
    end
  end

  describe 'AI opt-in gate (defence in depth)' do
    let(:organisation) { create(:organisation, ai_enabled: false) }
    let(:transcript) { 'Some transcript' }

    it 'does not call the LLM and records the ai_disabled error' do
      expect(Lalabase::Llm::Factory).not_to receive(:for_feature)
      described_class.call(analysis: analysis)
      analysis.reload
      expect(analysis.creation_error).to eq(I18n.t('services.meetings.analysis.ai_disabled'))
      expect(analysis.creation_flag).to be(false)
    end
  end

  describe 'provider routing follows the org choice (S1b)' do
    let(:transcript) { 'Some transcript' }
    let(:run_service) { -> { described_class.call(analysis: analysis) } }
    let(:metered_subject) { analysis }
    let(:assert_run_succeeded) { -> { expect(analysis.reload.content).to eq('Analyse-Ergebnis.') } }

    it_behaves_like 'a meeting LLM service routed by the org chat choice',
                    call_type: 'meeting_analysis',
                    feature_key: :meeting_analysis,
                    action: Lalabase::Llm::ActionRegistry::MEETING_ANALYSIS
  end
end
