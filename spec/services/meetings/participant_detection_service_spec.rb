# frozen_string_literal: true

require 'rails_helper'

# Meetings::ParticipantDetectionService — the LLM leg of the two-track
# participant detection (Gespräche Slice 5, plan decision 12).
#
# Intent: prove the transcript actually reaches the LLM prompt; prove the JSON
# answer is parsed DEFENSIVELY (code fences stripped, malformed JSON → status,
# never a raise); prove the name post-processing (normalize-dedupe, degenerate
# filter, cap) so a hostile/hallucinating model cannot flood the chips; prove
# usage is booked with the participant_detection action + triggering user; and
# prove every gate/LLM failure maps to a readable status symbol (the controller
# translates). All LLM traffic is stubbed at the Factory/provider seam.
#
# S1 (doc/ki_provider_reichweite_plan.md): the former pin to OpenAI + gpt-4o-mini
# is gone — this path follows the ORG's chat provider now. The routing block below
# drives the REAL Factory (only the provider CLASS is spied) so the two things that
# would break a Mistral/IONOS org are pinned at the decision point: which provider
# class gets built, and that no model literal travels along.
RSpec.describe Meetings::ParticipantDetectionService do
  let(:organisation) { create(:organisation, ai_enabled: true) }
  let(:user) { create(:user, organisation: organisation) }
  let(:transcript) { "**Anna Ananas:** Hallo zusammen.\n**Bert Bauer:** Guten Morgen." }

  let(:provider) { double('llm_provider') }
  let(:llm_content) { '["Anna Ananas", "Bert Bauer"]' }
  let(:chat_result) do
    { content: llm_content, token_usage: { total_tokens: 42 }, model_used: 'gpt-4o-mini' }
  end

  subject(:result) do
    # Drives the Klass.call entry point (service convention) — same instance path.
    described_class.call(organisation: organisation, transcript: transcript, user: user)
  end

  before do
    ActsAsTenant.current_tenant = organisation
    allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:meeting_participant_detection, organisation).and_return(provider)
    allow(provider).to receive(:chat).and_return(chat_result)
    allow(Lalabase::Llm::UsageTracking).to receive(:record)
  end

  after { ActsAsTenant.current_tenant = nil }

  describe 'prompt payload' do
    # Changed in S1: the old version asserted `build(provider_name: 'openai', …)`
    # and `sent[:model] == MODEL`. Both expectations pinned the migration artefact,
    # not a requirement — the org, not this service, owns the provider decision, and
    # a hard model literal is a 404 anywhere but OpenAI (plan §5 falle 1).
    it 'sends the transcript as the user message, rules as system, and NO model literal' do
      sent = nil
      allow(provider).to receive(:chat) do |**kwargs|
        sent = kwargs
        chat_result
      end

      result

      expect(Lalabase::Llm::Factory).to have_received(:for_feature).with(:meeting_participant_detection, organisation)
      expect(sent).not_to have_key(:model)
      # Instruction/data separation: the transcript is DATA in the user turn,
      # the extraction rules live in the system turn (prompt-injection hygiene).
      expect(sent[:messages].map { |m| m[:role] }).to eq(%w[system user])
      expect(sent[:messages].last[:content]).to include('**Anna Ananas:** Hallo zusammen.')
      expect(sent[:messages].first[:content]).to include('JSON')
    end
  end

  # The heart of S1: NOT stubbed at the Factory, so the real provider resolution
  # (org.ai_provider → PROVIDER_CLASSES → credentials) runs. Only the provider
  # CLASS is spied, which keeps the HTTP client out without hiding the routing.
  describe 'provider routing follows the org choice (S1)' do
    before do
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_call_original
      allow(Lalabase::Llm::OpenAiProvider).to receive(:new).and_return(provider)
      allow(Lalabase::Llm::OpenAiCompatibleProvider).to receive(:new).and_return(provider)
    end

    context 'with an org on an openai_compatible endpoint (e.g. Mistral EU, BYOK)' do
      let(:organisation) do
        create(:organisation, ai_enabled: true, ai_provider: 'openai_compatible',
                              ai_access_token: 'sk-mistral-own-token-1234567890',
                              ai_api_base: 'https://api.mistral.ai/v1')
      end

      it 'builds the org-compatible provider, never OpenAI' do
        expect(result).to be_success
        expect(Lalabase::Llm::OpenAiCompatibleProvider).to have_received(:new)
        expect(Lalabase::Llm::OpenAiProvider).not_to have_received(:new)
      end

      it 'sends no model literal — a gpt-4o-mini here is a runtime 404 at the endpoint' do
        sent = nil
        allow(provider).to receive(:chat) do |**kwargs|
          sent = kwargs
          chat_result
        end

        result

        expect(sent).not_to have_key(:model)
        expect(sent).to include(max_tokens: described_class::MAX_TOKENS,
                                temperature: described_class::TEMPERATURE)
      end

      it 'keeps the metering attribution unchanged' do
        expect(Lalabase::Llm::UsageTracking).to receive(:record).with(
          hash_including(organisation: organisation, call_type: 'meeting_participant_detection',
                         action: Lalabase::Llm::ActionRegistry::PARTICIPANT_DETECTION,
                         user: user, subject: nil)
        )
        result
      end
    end

    # Regression for an org that never made a choice (ai_provider default
    # 'openai'): the ROUTING is unchanged — same provider class, same credentials.
    context 'with an org without an own choice (default openai)' do
      context 'on a BYOK token without a preferred model' do
        let(:organisation) do
          create(:organisation, ai_enabled: true, ai_provider: 'openai',
                                ai_access_token: 'sk-org-own-1234567890')
        end

        it 'routes to OpenAI with no configured model — i.e. the old gpt-4o-mini literal' do
          expect(result).to be_success
          expect(Lalabase::Llm::OpenAiProvider).to have_received(:new).with(hash_including(chat_model: nil))
          expect(Lalabase::Llm::OpenAiCompatibleProvider).not_to have_received(:new)
          # chat_model: nil → OpenAiProvider#default_chat_model → DEFAULT_CHAT_MODEL,
          # which is exactly the model this service used to pass by hand.
          expect(Lalabase::Llm::OpenAiProvider::DEFAULT_CHAT_MODEL).to eq('gpt-4o-mini')
        end
      end

      # E2 of the plan, accepted consequence: on the SYSTEM credential the model is
      # no longer the hand-passed literal but the credential's default_model.
      # Pinned deliberately — this is the one behavioural change of S1 for orgs
      # that never touched a setting, and it must not happen unnoticed.
      context 'on the system credential' do
        before { create(:ai_credential, :active, provider: 'openai', default_model: 'gpt-4o') }

        it 'routes to OpenAI and inherits the credential model (E2)' do
          expect(result).to be_success
          expect(Lalabase::Llm::OpenAiProvider).to have_received(:new).with(hash_including(chat_model: 'gpt-4o'))
          expect(Lalabase::Llm::OpenAiCompatibleProvider).not_to have_received(:new)
        end
      end
    end
  end

  describe 'success' do
    it 'returns the detected names' do
      expect(result).to be_success
      expect(result.participants).to eq(['Anna Ananas', 'Bert Bauer'])
    end

    it 'books usage with the participant_detection action and the triggering user (no subject — nothing persisted)' do
      expect(Lalabase::Llm::UsageTracking).to receive(:record).with(
        hash_including(organisation: organisation, provider: provider,
                       call_type: 'meeting_participant_detection',
                       action: Lalabase::Llm::ActionRegistry::PARTICIPANT_DETECTION,
                       user: user, subject: nil)
      )
      result
    end

    context 'with markdown code fences around the JSON' do
      let(:llm_content) { "```json\n[\"Anna Ananas\"]\n```" }

      it 'strips the fences and parses the array' do
        expect(result).to be_success
        expect(result.participants).to eq(['Anna Ananas'])
      end
    end

    context 'with an empty array (no participants recognised)' do
      let(:llm_content) { '[]' }

      it 'is a success with no names (valid answer, not an error)' do
        expect(result).to be_success
        expect(result.participants).to eq([])
      end
    end
  end

  describe 'name post-processing (defence against a hallucinating model)' do
    context 'with duplicates that only differ by case/whitespace/umlaut transliteration' do
      let(:llm_content) { '["Jürgen Müller", "  juergen   mueller ", "Anna Ananas"]' }

      it 'dedupes via MeetingParticipant.normalize_name, first spelling wins' do
        expect(result.participants).to eq(['Jürgen Müller', 'Anna Ananas'])
      end
    end

    context 'with degenerate entries' do
      let(:llm_content) { %(["Anna Ananas", "", "   ", 42, {"x":1}, "#{'A' * 300}"]) }

      it 'drops blanks, non-strings and absurdly long names' do
        expect(result).to be_success
        expect(result.participants).to eq(['Anna Ananas'])
      end
    end

    context 'with more names than the cap' do
      let(:llm_content) { (1..60).map { |i| "Person Nr#{i}" }.to_json }

      it "caps the list at #{described_class::MAX_PARTICIPANTS} names" do
        expect(result.participants.length).to eq(described_class::MAX_PARTICIPANTS)
      end
    end
  end

  describe 'malformed LLM answer' do
    context 'with non-JSON prose' do
      let(:llm_content) { 'Die Teilnehmer waren Anna und Bert.' }

      it 'returns :parse_error instead of raising' do
        expect(result.status).to eq(:parse_error)
        expect(result.participants).to eq([])
      end

      it 'still books usage — the LLM call happened and cost credits' do
        expect(Lalabase::Llm::UsageTracking).to receive(:record)
        result
      end
    end

    context 'with a JSON object that has no participants array' do
      let(:llm_content) { '{"answer": "none"}' }

      it 'returns :parse_error' do
        expect(result.status).to eq(:parse_error)
      end
    end

    context 'with a JSON object wrapping the array under "participants"' do
      let(:llm_content) { '{"participants": ["Anna Ananas"]}' }

      it 'tolerates the wrapper shape' do
        expect(result).to be_success
        expect(result.participants).to eq(['Anna Ananas'])
      end
    end
  end

  describe 'error mapping (status symbols, never a raise)' do
    {
      'Lalabase::Llm::Factory::MissingCredentialError' => :not_configured,
      'Lalabase::Llm::QuotaExceededError' => :quota_exceeded,
      'Lalabase::Llm::AiDisabledError' => :ai_disabled,
      'Lalabase::Llm::Provider::AuthError' => :invalid_key
    }.each do |error_class, status|
      context "when the seam raises #{error_class}" do
        before { allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:meeting_participant_detection, organisation).and_raise(error_class.constantize) }

        it "maps to :#{status}" do
          expect { result }.not_to raise_error
          expect(result.status).to eq(status)
          expect(result.participants).to eq([])
        end
      end
    end

    context 'when an unexpected StandardError is raised' do
      before { allow(provider).to receive(:chat).and_raise(StandardError, 'boom') }

      it 'maps to :error' do
        expect { result }.not_to raise_error
        expect(result.status).to eq(:error)
      end
    end
  end

  describe 'AI opt-in gate (defence in depth — the controller re-checks too)' do
    let(:organisation) { create(:organisation, ai_enabled: false) }

    it 'returns :ai_disabled without ever touching the Factory' do
      expect(Lalabase::Llm::Factory).not_to receive(:for_feature)
      expect(result.status).to eq(:ai_disabled)
    end
  end
end
