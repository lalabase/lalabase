# frozen_string_literal: true

require 'rails_helper'

# Meetings::SummaryService — the async summary generator for a meeting.
#
# Intent: prove the SOURCE rule (transcript preferred, notes fallback — plan
# decision 11) on the text actually handed to the LLM; prove usage is tracked on
# success; and prove every gate/LLM failure maps to a readable
# summary_creation_error while the pending flag is ALWAYS cleared (never a stuck
# spinner, never a 500). All LLM traffic is stubbed at the Factory/provider seam.
RSpec.describe Meetings::SummaryService do
  let(:organisation) { create(:organisation, ai_enabled: true) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user, organisation: organisation) }

  let(:transcript) { nil }
  let(:notes) { nil }
  let(:meeting) do
    create(:meeting, organisation: organisation, project: project, creator: user,
                     transcript: transcript, notes: notes, summary_creation_flag: true)
  end

  let(:provider) { double('llm_provider') }
  let(:chat_result) do
    { content: 'Kurzfassung des Gesprächs.', token_usage: { total_tokens: 42 }, model_used: 'gpt-4o-mini' }
  end

  before do
    ActsAsTenant.current_tenant = organisation
    allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:meeting_summary, organisation).and_return(provider)
    allow(provider).to receive(:chat).and_return(chat_result)
    allow(Lalabase::Llm::UsageTracking).to receive(:record)
  end

  after { ActsAsTenant.current_tenant = nil }

  # Capture the text actually handed to the LLM, so the source/fallback rule is
  # asserted on the real prompt payload rather than an intermediate value.
  def prompt_sent
    messages = nil
    allow(provider).to receive(:chat) do |**kwargs|
      messages = kwargs[:messages]
      chat_result
    end
    described_class.call(meeting: meeting)
    messages.first[:content]
  end

  describe 'source selection (transcript preferred, notes fallback)' do
    context 'with a transcript AND notes' do
      let(:transcript) { 'VERBATIM_TRANSCRIPT_XYZ' }
      let(:notes) { 'CURATED_NOTES_ABC' }

      it 'summarizes the transcript, not the notes' do
        text = prompt_sent
        expect(text).to include('VERBATIM_TRANSCRIPT_XYZ')
        expect(text).not_to include('CURATED_NOTES_ABC')
      end
    end

    context 'with notes but no transcript' do
      let(:notes) { 'CURATED_NOTES_ABC' }

      it 'summarizes the notes' do
        expect(prompt_sent).to include('CURATED_NOTES_ABC')
      end
    end

    context 'with a whitespace-only transcript and real notes' do
      let(:transcript) { "  \n\t  " }
      let(:notes) { 'CURATED_NOTES_ABC' }

      it 'falls back to the notes (transcript.presence is blank)' do
        expect(prompt_sent).to include('CURATED_NOTES_ABC')
      end
    end

    context 'with neither notes nor transcript' do
      it 'does not call the LLM and clears the pending flag' do
        expect(Lalabase::Llm::Factory).not_to receive(:for_feature)
        described_class.call(meeting: meeting)
        expect(meeting.reload.summary_creation_flag).to be(false)
        expect(meeting.generated_summary).to eq('')
      end

      # Review #235: this branch used to keep an OLD error while clearing the
      # flag — the view then showed a stale failure text plus a retry button
      # instead of the no-content hint.
      it 'clears a leftover error so the view falls through to the no-content hint' do
        meeting.update!(summary_creation_error: 'alter Fehler')
        described_class.call(meeting: meeting)
        expect(meeting.reload.summary_creation_error).to eq('')
      end
    end
  end

  # Review #235: a 1 MB transcript exceeds the model context and would 400 on
  # every attempt — the source is capped BEFORE the LLM call. And only the
  # instructions are squished: the source keeps its speaker-turn newlines.
  describe 'prompt construction' do
    context 'with an oversized transcript' do
      let(:transcript) { "K#{'a' * (described_class::SOURCE_CHAR_LIMIT + 5_000)}" }

      it 'caps the source and marks the truncation' do
        text = prompt_sent
        expect(text.length).to be < described_class::SOURCE_CHAR_LIMIT + 1_000
        expect(text).to include('gekürzt')
      end
    end

    context 'with a dialogue transcript' do
      let(:transcript) { "Anna: Wir starten mit Q3.\nBert: Einverstanden." }

      it 'preserves the speaker-turn newlines in the prompt' do
        expect(prompt_sent).to include("Anna: Wir starten mit Q3.\nBert: Einverstanden.")
      end
    end

    # AI transcript exports lead with a YAML frontmatter block; it is metadata noise
    # the LLM should never summarise. summary_source strips it, so the prompt payload
    # carries only the real content.
    context 'with a leading YAML frontmatter block' do
      let(:transcript) { "---\nid: meeting-777\nparent: projekt-9\n---\nAnna: Wir starten mit Q3." }

      it 'sends the content but NOT the frontmatter lines to the LLM' do
        text = prompt_sent
        expect(text).to include('Anna: Wir starten mit Q3.')
        expect(text).not_to include('id: meeting-777')
        expect(text).not_to include('parent: projekt-9')
      end
    end
  end

  describe 'success' do
    let(:transcript) { 'Some transcript' }

    it 'persists the summary and clears the flag and error' do
      described_class.call(meeting: meeting)
      meeting.reload
      expect(meeting.generated_summary).to eq('Kurzfassung des Gesprächs.')
      expect(meeting.summary_creation_flag).to be(false)
      expect(meeting.summary_creation_error).to eq('')
    end

    it 'records usage via UsageTracking with the summary action + meeting subject' do
      # S3 KI-Kontingent: the seam requires `action`; pin it (and the subject) so a
      # meeting summary bills the flat 'summary' action for the quota, like the
      # document/ticket summaries. (verify_partial_doubles already rejects a call
      # missing the required action — this pins the VALUE.)
      expect(Lalabase::Llm::UsageTracking).to receive(:record).with(
        hash_including(organisation: organisation, provider: provider, call_type: 'meeting_summary',
                       action: Lalabase::Llm::ActionRegistry::SUMMARY, subject: meeting)
      )
      described_class.call(meeting: meeting)
    end
  end

  describe 'empty LLM result' do
    let(:transcript) { 'Some transcript' }
    let(:chat_result) { { content: '   ', token_usage: {}, model_used: 'gpt-4o-mini' } }

    it 'records the empty-result error and clears the flag' do
      described_class.call(meeting: meeting)
      meeting.reload
      expect(meeting.generated_summary).to eq('')
      expect(meeting.summary_creation_flag).to be(false)
      expect(meeting.summary_creation_error).to eq(I18n.t('services.meetings.summary.empty_result'))
    end
  end

  describe 'error mapping (flag always cleared, no raise)' do
    let(:transcript) { 'Some transcript' }

    {
      'Lalabase::Llm::Factory::MissingCredentialError' => 'not_configured',
      'Lalabase::Llm::AiDisabledError' => 'ai_disabled',
      'Lalabase::Llm::Provider::AuthError' => 'invalid_key'
    }.each do |error_class, key|
      context "when the provider raises #{error_class}" do
        before { allow(provider).to receive(:chat).and_raise(error_class.constantize) }

        it "maps to the #{key} message and clears the flag" do
          expect { described_class.call(meeting: meeting) }.not_to raise_error
          meeting.reload
          expect(meeting.summary_creation_error).to eq(I18n.t("services.meetings.summary.#{key}"))
          expect(meeting.summary_creation_flag).to be(false)
        end
      end
    end

    context 'when an unexpected StandardError is raised' do
      before { allow(provider).to receive(:chat).and_raise(StandardError, 'boom') }

      it 'maps to the generic error and clears the flag' do
        expect { described_class.call(meeting: meeting) }.not_to raise_error
        meeting.reload
        expect(meeting.summary_creation_error).to eq(I18n.t('services.meetings.summary.generic_error'))
        expect(meeting.summary_creation_flag).to be(false)
      end
    end

    # S3 KI-Kontingent (merge integration): the gated seam raises QuotaExceededError
    # at Factory.build when the org's quota is exhausted — it must map to the
    # quota-specific message, NOT the generic error (which is what a missing rescue
    # would produce).
    context 'when the gate raises QuotaExceededError (quota exhausted)' do
      before { allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:meeting_summary, organisation).and_raise(Lalabase::Llm::QuotaExceededError) }

      it 'maps to the quota-exhausted message and clears the flag' do
        expect { described_class.call(meeting: meeting) }.not_to raise_error
        meeting.reload
        expect(meeting.summary_creation_error).to eq(I18n.t('services.meetings.summary.quota_exhausted'))
        expect(meeting.summary_creation_flag).to be(false)
      end
    end
  end

  describe 'AI opt-in gate (defence in depth)' do
    let(:organisation) { create(:organisation, ai_enabled: false) }
    let(:transcript) { 'Some transcript' }

    it 'does not call the LLM and records the ai_disabled error' do
      expect(Lalabase::Llm::Factory).not_to receive(:for_feature)
      described_class.call(meeting: meeting)
      meeting.reload
      expect(meeting.summary_creation_error).to eq(I18n.t('services.meetings.summary.ai_disabled'))
      expect(meeting.summary_creation_flag).to be(false)
    end
  end

  describe 'provider routing follows the org choice (S1b)' do
    let(:transcript) { 'Some transcript' }
    let(:run_service) { -> { described_class.call(meeting: meeting) } }
    let(:metered_subject) { meeting }
    let(:assert_run_succeeded) do
      -> { expect(meeting.reload.generated_summary).to eq('Kurzfassung des Gesprächs.') }
    end

    it_behaves_like 'a meeting LLM service routed by the org chat choice',
                    call_type: 'meeting_summary',
                    feature_key: :meeting_summary,
                    action: Lalabase::Llm::ActionRegistry::SUMMARY
  end
end
