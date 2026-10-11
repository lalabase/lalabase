# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SummaryProcessingService do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }
  let(:document) { create(:document, project: project, organisation: organisation, creator: user) }
  let(:uploaded_file) { fixture_file_upload('spec/fixtures/files/test_file.txt', 'text/plain') }
  let(:plain_text) { 'Dies ist ein langer Testtext mit vielen Informationen über das Projekt.' }
  let(:document_version) do
    create(:document_version,
           document: document,
           organisation: organisation,
           document_version_file: uploaded_file,
           plain_text_version: plain_text,
           create_summary: true)
  end

  # S2: the service routes through the Lalabase::Llm::Factory seam, which returns
  # a Provider whose #chat yields a NORMALISED hash ({content:, token_usage:, ...}) —
  # not the raw OpenAI {'choices' => ...} shape the removed AiClientWrapper exposed.
  # S1 (doc/ki_provider_reichweite_plan.md): the ORG picks the provider; the former
  # pin to OpenAI + gpt-4o-mini is gone. KI-Pakete P3 made the seam
  # .for_feature(:document_summary, org) — the SAME registry row the gate reads.
  # Every stub is KEY-SCOPED: a blanket `receive(:for_feature)` answers for any
  # key, and with all unpinned chat rows resolving alike today, a wrong key would
  # pass unnoticed.
  let(:provider) { instance_double(Lalabase::Llm::OpenAiProvider, billing_credential: nil, provider_name: 'openai') }
  let(:summary_text) { 'Das Dokument beschreibt ein Projekt mit technischen Details. 1 Seite, keine Bilder.' }
  let(:chat_result) do
    { content: summary_text, model_used: 'gpt-4o-mini',
      token_usage: { input_tokens: 20, output_tokens: 10, total_tokens: 30 } }
  end

  before do
    ActsAsTenant.current_tenant = organisation
    # Isolate the summary logic from usage tracking (its own spec covers tracking);
    # a dedicated regression context below exercises the real tracking path.
    allow(Lalabase::Llm::UsageTracking).to receive(:record)
  end

  around do |example|
    ActsAsTenant.with_tenant(organisation) { example.run }
  end

  describe '#initialize' do
    it 'stores the record' do
      expect(described_class.new(document_version).record).to eq(document_version)
    end

    it 'reads plain_text_version from the record' do
      expect(described_class.new(document_version).instance_variable_get(:@text)).to eq(plain_text)
    end
  end

  describe '#process' do
    # GDPR AI opt-in (audit 2026-07-03): quiet skip, NO error text persisted — without
    # the guard the seam's AiDisabledError fell into the broad rescue and wrote raw
    # English exception text into the user-visible summary_creation_error column.
    context 'when the organisation has not opted in to AI (GDPR gate)' do
      before { organisation.update!(ai_enabled: false) }

      it 'skips quietly — no provider resolution, no error text, no flag flip' do
        expect(Lalabase::Llm::Factory).not_to receive(:for_feature)

        expect { described_class.new(document_version).process }.not_to raise_error

        document_version.reload
        expect(document_version.summary_creation_error).to be_blank
        expect(document_version.summary_creation_flag).not_to be true
      end
    end

    context 'when plain_text_version is nil' do
      let(:document_version) do
        create(:document_version, document: document, organisation: organisation,
                                  document_version_file: uploaded_file, plain_text_version: nil)
      end

      it 'returns nil without calling AI' do
        expect(Lalabase::Llm::Factory).not_to receive(:for_feature)
        expect(described_class.new(document_version).process).to be_nil
      end
    end

    context 'when plain_text_version is an empty string' do
      let(:document_version) do
        create(:document_version, document: document, organisation: organisation,
                                  document_version_file: uploaded_file, plain_text_version: '')
      end

      it 'returns nil without calling AI' do
        expect(Lalabase::Llm::Factory).not_to receive(:for_feature)
        expect(described_class.new(document_version).process).to be_nil
      end
    end

    context 'when no LLM provider is available (missing credential)' do
      before do
        allow(Lalabase::Llm::Factory).to receive(:for_feature)
          .with(:document_summary, organisation)
          .and_raise(Lalabase::Llm::Factory::MissingCredentialError, 'no credential')
      end

      it 'sets the ai_unavailable error message on the record' do
        described_class.new(document_version).process
        expect(document_version.reload.summary_creation_error)
          .to eq(I18n.t('services.summary_processing.ai_unavailable'))
      end

      it 'does not set summary_creation_flag' do
        described_class.new(document_version).process
        expect(document_version.reload.summary_creation_flag).to be false
      end

      it 'logs an error' do
        allow(Rails.logger).to receive(:error)
        described_class.new(document_version).process
        expect(Rails.logger).to have_received(:error).with('No LLM provider available for summary processing')
      end
    end

    context 'when organisation is nil' do
      before { allow(document_version).to receive(:organisation).and_return(nil) }

      # A nil org takes the quiet fail-closed skip (same contract as
      # EmbeddingProcessingService), not a user-visible failure.
      it 'skips quietly without persisting an error' do
        described_class.new(document_version).process
        document_version.reload
        expect(document_version.summary_creation_error).to be_blank
        expect(document_version.summary_creation_flag).not_to be true
      end
    end

    context 'happy path' do
      before do
        allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:document_summary, organisation).and_return(provider)
        allow(provider).to receive(:chat).and_return(chat_result)
      end

      it 'stores the generated summary on the record' do
        described_class.new(document_version).process
        expect(document_version.reload.generated_summary).to eq(summary_text)
      end

      it 'sets summary_creation_flag to true' do
        described_class.new(document_version).process
        expect(document_version.reload.summary_creation_flag).to be true
      end

      # Replaces "sends the task-specific model to the provider": that expectation
      # was correct only as long as OpenAI was the only destination. The model is
      # now resolved by the factory precedence (org.preferred_chat_model >
      # credential.default_model > provider constant); passing one from here would
      # be a runtime 404 at any non-OpenAI endpoint (plan §5 falle 1).
      it 'passes NO model — the org/credential decides which model answers' do
        described_class.new(document_version).process
        expect(provider).to have_received(:chat) { |args| expect(args).not_to have_key(:model) }
      end

      # Replaces "pins the provider to OpenAI — must NOT follow org.ai_provider".
      # That pin was a migration artefact, not a requirement: an upload's plain text
      # is arbitrary customer content, so the org's provider choice has to govern it
      # (plan §2.1 P2). The routing block below proves the org choice really arrives.
      it 'resolves the provider through the org-aware, feature-keyed seam' do
        described_class.new(document_version).process
        expect(Lalabase::Llm::Factory).to have_received(:for_feature).with(:document_summary, organisation)
      end

      # Replaces "preserves the presence_penalty knob via provider_options".
      # provider_options is merged verbatim into the vendor request, so top_p /
      # frequency_penalty / presence_penalty would reach Anthropic and Gemini as
      # unknown fields (400). Two of the three were OpenAI defaults; the third's
      # intent ("do not repeat yourself") is stated in the prompt itself.
      it 'sends no OpenAI-dialect provider_options' do
        described_class.new(document_version).process
        expect(provider).to have_received(:chat) { |args| expect(args).not_to have_key(:provider_options) }
      end

      it 'includes the document text in the prompt' do
        described_class.new(document_version).process
        expect(provider).to have_received(:chat) do |args|
          expect(args[:messages][0][:content]).to include(plain_text)
        end
      end

      it 'clears any previous error' do
        document_version.update_columns(summary_creation_error: 'Alter Fehler')
        described_class.new(document_version).process
        expect(document_version.reload.summary_creation_flag).to be true
      end
    end

    context 'when the provider returns an empty summary' do
      before do
        allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:document_summary, organisation).and_return(provider)
        allow(provider).to receive(:chat).and_return(chat_result.merge(content: ''))
      end

      it 'sets summary_creation_error' do
        described_class.new(document_version).process
        expect(document_version.reload.summary_creation_error)
          .to eq(I18n.t('services.summary_processing.summary_error'))
      end

      it 'does not set summary_creation_flag to true' do
        described_class.new(document_version).process
        expect(document_version.reload.summary_creation_flag).to be false
      end
    end

    context 'when the provider raises' do
      before do
        allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:document_summary, organisation).and_return(provider)
      end

      it 'stores the error message and clears the flag (StandardError)' do
        allow(provider).to receive(:chat).and_raise(StandardError, 'API timeout')
        described_class.new(document_version).process
        document_version.reload
        expect(document_version.summary_creation_flag).to be false
        expect(document_version.summary_creation_error).to eq('API timeout')
      end

      it 'handles network errors and stores the message (Faraday::Error)' do
        allow(provider).to receive(:chat).and_raise(Faraday::ConnectionFailed, 'Connection refused')
        described_class.new(document_version).process
        document_version.reload
        expect(document_version.summary_creation_flag).to be false
        expect(document_version.summary_creation_error).to include('Connection refused')
      end

      it 'logs the error with record context' do
        allow(provider).to receive(:chat).and_raise(StandardError, 'API timeout')
        allow(Rails.logger).to receive(:error)
        described_class.new(document_version).process
        expect(Rails.logger).to have_received(:error)
          .with(/Fehler bei der Summary-Erstellung für DocumentVersion mit ID #{document_version.id}: API timeout/)
      end
    end

    # S1: dropping the hardcoded model made this failure mode reachable for the
    # first time — the org's endpoint may not know the model, or may have none
    # configured at all. summary_creation_error is USER-VISIBLE, so a raw English
    # provider exception must not be persisted there (plan §4 S1).
    context 'when the org provider itself fails (Provider::Error)' do
      before do
        allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:document_summary, organisation).and_return(provider)
        allow(provider).to receive(:chat)
          .and_raise(Lalabase::Llm::Provider::Error, 'openai_compatible provider requires a chat model')
      end

      it 'persists the localised copy, never the raw exception text' do
        described_class.new(document_version).process
        document_version.reload
        expect(document_version.summary_creation_error)
          .to eq(I18n.t('services.summary_processing.provider_error'))
        expect(document_version.summary_creation_error).not_to include('openai_compatible provider requires')
        expect(document_version.summary_creation_flag).to be false
      end

      it 'still logs the real provider message for operations' do
        allow(Rails.logger).to receive(:error)
        described_class.new(document_version).process
        expect(Rails.logger).to have_received(:error)
          .with(/Summary provider error.*openai_compatible provider requires a chat model/)
      end

      # Ordering guard: QuotaExceededError inherits from Provider::Error. If the
      # new rescue were placed above it, an exhausted quota would stop being a
      # quiet skip and start writing a defect message onto every upload.
      it 'does not swallow the quota pause (quiet skip keeps winning)' do
        allow(provider).to receive(:chat).and_raise(Lalabase::Llm::QuotaExceededError, 'quota')
        described_class.new(document_version).process
        document_version.reload
        expect(document_version.summary_creation_error).to be_blank
        expect(document_version.summary_creation_flag).not_to be true
      end
    end

    # The heart of S1: NOT stubbed at the Factory, so the real provider resolution
    # (org.ai_provider → PROVIDER_CLASSES → credentials) runs. Only the provider
    # CLASS is spied, which keeps the HTTP client out without hiding the routing.
    describe 'provider routing follows the org choice (S1)' do
      before do
        allow(Lalabase::Llm::OpenAiProvider).to receive(:new).and_return(provider)
        allow(Lalabase::Llm::OpenAiCompatibleProvider).to receive(:new).and_return(provider)
        allow(provider).to receive(:chat).and_return(chat_result)
      end

      context 'with an org on an openai_compatible endpoint (e.g. Mistral EU, BYOK)' do
        let(:organisation) do
          create(:organisation, ai_enabled: true, ai_provider: 'openai_compatible',
                                ai_access_token: 'sk-mistral-own-token-1234567890',
                                ai_api_base: 'https://api.mistral.ai/v1')
        end

        it 'builds the org-compatible provider, never OpenAI' do
          described_class.new(document_version).process
          expect(Lalabase::Llm::OpenAiCompatibleProvider).to have_received(:new)
          expect(Lalabase::Llm::OpenAiProvider).not_to have_received(:new)
          expect(document_version.reload.generated_summary).to eq(summary_text)
        end

        it 'sends no model literal — a gpt-4o-mini here is a runtime 404 at the endpoint' do
          described_class.new(document_version).process
          expect(provider).to have_received(:chat) do |args|
            expect(args).not_to have_key(:model)
            expect(args).to include(max_tokens: described_class::MAX_TOKENS,
                                    temperature: described_class::TEMPERATURE)
          end
        end

        it 'keeps the metering attribution unchanged' do
          expect(Lalabase::Llm::UsageTracking).to receive(:record).with(
            hash_including(organisation: organisation, call_type: 'document_summary',
                           action: Lalabase::Llm::ActionRegistry::SUMMARY, subject: document_version)
          )
          described_class.new(document_version).process
        end
      end

      # Regression for an org that never made a choice (ai_provider default
      # 'openai'): the ROUTING is unchanged — same provider class, same credential
      # resolution, same summary.
      context 'with an org without an own choice (default openai)' do
        context 'on a BYOK token without a preferred model' do
          before { organisation.update!(ai_provider: 'openai', ai_access_token: 'sk-org-own-1234567890') }

          it 'routes to OpenAI with no configured model — i.e. the old gpt-4o-mini literal' do
            described_class.new(document_version).process
            expect(Lalabase::Llm::OpenAiProvider).to have_received(:new).with(hash_including(chat_model: nil))
            expect(Lalabase::Llm::OpenAiCompatibleProvider).not_to have_received(:new)
            # chat_model: nil → OpenAiProvider#default_chat_model → DEFAULT_CHAT_MODEL,
            # which is exactly the model this service used to pass by hand.
            expect(Lalabase::Llm::OpenAiProvider::DEFAULT_CHAT_MODEL).to eq('gpt-4o-mini')
            expect(document_version.reload.generated_summary).to eq(summary_text)
          end
        end

        # E2 of the plan, accepted consequence: on the SYSTEM credential the model
        # is no longer the hand-passed literal but the credential's default_model.
        # Pinned deliberately — this is the one behavioural change of S1 for orgs
        # that never touched a setting, and it must not happen unnoticed.
        context 'on the system credential' do
          before { create(:ai_credential, :active, provider: 'openai', default_model: 'gpt-4o') }

          it 'routes to OpenAI and inherits the credential model (E2)' do
            described_class.new(document_version).process
            expect(Lalabase::Llm::OpenAiProvider).to have_received(:new).with(hash_including(chat_model: 'gpt-4o'))
            expect(Lalabase::Llm::OpenAiCompatibleProvider).not_to have_received(:new)
            expect(document_version.reload.generated_summary).to eq(summary_text)
          end
        end
      end
    end

    # S2 regression: the migrated caller must still record usage, and a BYOK org's
    # usage must NEVER be attributed to the system credential.
    context 'usage tracking (S2 regression)' do
      before do
        allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:document_summary, organisation).and_return(provider)
        allow(provider).to receive(:chat).and_return(chat_result)
        allow(Lalabase::Llm::UsageTracking).to receive(:record).and_call_original
      end

      it 'writes exactly one AiUsage row for the call' do
        expect { described_class.new(document_version).process }.to change(AiUsage, :count).by(1)
        expect(AiUsage.last.tokens_used).to eq(30)
      end

      it 'attributes a BYOK org to a nil credential, never the system credential' do
        create(:ai_credential, :active, provider: 'openai')
        organisation.update!(ai_provider: 'openai', ai_access_token: 'sk-org-own-1234567890')

        described_class.new(document_version).process
        expect(AiUsage.last.ai_credential).to be_nil
      end
    end
  end
end
