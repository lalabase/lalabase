# frozen_string_literal: true

# S1b (doc/ki_provider_reichweite_plan.md): AnalysisService, SummaryService and
# TicketSuggestionService route through ONE line in Meetings::BaseLlmService —
# formerly Factory.build(provider_name: PROVIDER) with PROVIDER = 'openai', then
# Factory.for_chat(organisation), and since KI-Pakete P3
# Factory.for_feature(<the subclass's own key>, organisation). One hebel, three
# services, so ONE shared contract instead of three copies that could drift
# apart silently.
#
# What makes this bite (rather than just add coverage): the Factory is NOT
# stubbed here. The real provider resolution runs (org.ai_provider →
# PROVIDER_CLASSES → credential precedence) and only the provider CLASS is spied,
# which keeps the HTTP client out without hiding the routing decision. Re-pinning
# the base to 'openai' therefore fails on the provider-class expectation, and
# re-introducing a `model:` literal in a subclass fails on the payload expectation.
#
# `feature_key:` is not decoration: the including spec stubs for_feature for its
# OWN key in an outer before, and this group has to unstub exactly that pairing
# to reach the real resolution. Naming the wrong key here leaves the double in
# place and every example below fails on "provider class never built" — which is
# the loud failure a blanket and_call_original would have swallowed.
#
# Contract the including spec must supply:
#   let(:provider)             — the chat double (its #chat returns chat_result)
#   let(:chat_result)          — normalised provider answer
#   let(:run_service)          — lambda running the service for `meeting`
#   let(:metered_subject)      — the record UsageTracking books the call against
#   let(:assert_run_succeeded) — lambda asserting the service-specific success
# plus a non-blank meeting source, and an `organisation` let this group overrides.
RSpec.shared_examples 'a meeting LLM service routed by the org chat choice' do |call_type:, action:, feature_key:|
  before do
    allow(Lalabase::Llm::Factory).to receive(:for_feature).with(feature_key, organisation).and_call_original
    allow(Lalabase::Llm::OpenAiProvider).to receive(:new).and_return(provider)
    allow(Lalabase::Llm::OpenAiCompatibleProvider).to receive(:new).and_return(provider)
  end

  context 'with an org on an openai_compatible endpoint (e.g. Mistral EU, BYOK)' do
    let(:organisation) do
      create(:organisation, ai_enabled: true, ai_provider: 'openai_compatible',
                            ai_access_token: 'sk-mistral-own-token-1234567890',
                            ai_api_base: 'https://api.mistral.ai/v1',
                            preferred_chat_model: 'mistral-small-latest')
    end

    it 'builds the org-compatible provider, never OpenAI' do
      run_service.call
      expect(Lalabase::Llm::OpenAiCompatibleProvider).to have_received(:new)
      expect(Lalabase::Llm::OpenAiProvider).not_to have_received(:new)
      assert_run_succeeded.call
    end

    it 'sends no model literal — a gpt-4o-mini here is a runtime 404 at the endpoint' do
      sent = nil
      allow(provider).to receive(:chat) do |**kwargs|
        sent = kwargs
        chat_result
      end

      run_service.call

      expect(sent).not_to have_key(:model)
      # provider_options is merged VERBATIM into the vendor request — an
      # OpenAI-dialect knob travelling here is a 400 on an unknown field.
      expect(sent).not_to have_key(:provider_options)
      expect(sent[:messages]).to be_present
    end

    it 'takes the model from the ORG, not from the service' do
      run_service.call
      expect(Lalabase::Llm::OpenAiCompatibleProvider)
        .to have_received(:new).with(hash_including(chat_model: 'mistral-small-latest'))
    end

    # Falle 4 of the plan: the provider switch must not shift the metering
    # attribution, or costs walk past the quota seam.
    it 'keeps the metering attribution unchanged' do
      expect(Lalabase::Llm::UsageTracking).to receive(:record).with(
        hash_including(organisation: organisation, call_type: call_type,
                       action: action, subject: metered_subject)
      )
      run_service.call
    end
  end

  # Regression for an org that never made a choice (ai_provider default 'openai'):
  # the ROUTING is unchanged — same provider class, same credential resolution.
  context 'with an org without an own choice (default openai)' do
    context 'on a BYOK token without a preferred model' do
      let(:organisation) do
        create(:organisation, ai_enabled: true, ai_provider: 'openai',
                              ai_access_token: 'sk-org-own-1234567890')
      end

      it 'routes to OpenAI with no configured model — i.e. the old gpt-4o-mini literal' do
        run_service.call
        expect(Lalabase::Llm::OpenAiProvider).to have_received(:new).with(hash_including(chat_model: nil))
        expect(Lalabase::Llm::OpenAiCompatibleProvider).not_to have_received(:new)
        # chat_model: nil → OpenAiProvider#default_chat_model → DEFAULT_CHAT_MODEL,
        # which is exactly the model these services used to pass by hand.
        expect(Lalabase::Llm::OpenAiProvider::DEFAULT_CHAT_MODEL).to eq('gpt-4o-mini')
        assert_run_succeeded.call
      end
    end

    # E2 of the plan, accepted consequence: on the SYSTEM credential the model is
    # no longer the hand-passed literal but the credential's default_model. Pinned
    # deliberately — this is the one behavioural change of S1b for orgs that never
    # touched a setting, and it must not happen unnoticed.
    context 'on the system credential' do
      before { create(:ai_credential, :active, provider: 'openai', default_model: 'gpt-4o') }

      it 'routes to OpenAI and inherits the credential model (E2)' do
        run_service.call
        expect(Lalabase::Llm::OpenAiProvider).to have_received(:new).with(hash_including(chat_model: 'gpt-4o'))
        expect(Lalabase::Llm::OpenAiCompatibleProvider).not_to have_received(:new)
        assert_run_succeeded.call
      end
    end
  end
end
