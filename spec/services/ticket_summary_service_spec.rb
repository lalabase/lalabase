# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TicketSummaryService do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end
  let(:ticket) do
    ActsAsTenant.current_tenant = organisation
    create(:ticket, project: project, creator: user, content: 'Ausgangslage: Login ist langsam.')
  end
  let!(:reply) do
    ActsAsTenant.current_tenant = organisation
    create(:post, ticket: ticket, user: user, organisation: organisation, content: 'Ursache gefunden: N+1 Query.')
  end

  let(:service) { described_class.new(ticket: ticket, organisation: organisation, updater: user) }

  before do
    ActsAsTenant.current_tenant = organisation
    # Isolate summary logic from tracking (its own spec covers it).
    allow(Lalabase::Llm::UsageTracking).to receive(:record)
  end

  # The service routes through the Lalabase::Llm::Factory seam and reads the
  # NORMALISED provider result ({content:, token_usage:, model_used:}).
  # S2 (doc/ki_provider_reichweite_plan.md, P3): the ORG picks the provider; the
  # former pin to OpenAI + gpt-4o-mini is gone. KI-Pakete P3 made the seam
  # .for_feature(:ticket_summary, org) — the SAME registry row the gate reads,
  # and the row that marks this path as utility.
  #
  # Every stub here is KEY-SCOPED (.with(:ticket_summary, …)). A blanket
  # `receive(:for_feature)` would answer for any key, and since all unpinned chat
  # rows resolve identically today, a wrong key would be invisible.
  def provider_returning(summary_text)
    instance_double(Lalabase::Llm::OpenAiProvider, billing_credential: nil, provider_name: 'openai').tap do |provider|
      allow(provider).to receive(:chat).and_return(
        content: summary_text, model_used: 'gpt-4o-mini',
        token_usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 }
      )
    end
  end

  # Gate AND routing are stubbed on the same key on purpose — that pairing IS the
  # contract since KI-Pakete P3 (both read the :ticket_summary registry row).
  def stub_provider(provider)
    allow(organisation).to receive(:ai_available_for?).with(:ticket_summary).and_return(available)
    allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:ticket_summary, organisation).and_return(provider)
  end

  def available
    Lalabase::Llm::FeatureRegistry::Availability.new(available: true)
  end

  def unavailable(reason)
    Lalabase::Llm::FeatureRegistry::Availability.new(available: false, reason: reason)
  end

  describe '#call' do
    # THE two failure states this service keeps apart. Since KI-Pakete P3 both
    # come off ONE question (ai_available_for?(:ticket_summary)) and are split by
    # #unavailable_status — so the pair below pins the MAPPING from the registry's
    # reason, and the "real organisation state" pair further down proves the real
    # org data still reaches each branch.
    #
    # What the mapping must not lose: :ai_disabled has its own surface (the opt-in
    # explanation), every other reason shares the setup modal. Collapsing the two
    # makes every opted-out org answer :no_api_key with nothing crashing.
    context 'when the organisation has not opted in to AI (GDPR gate)' do
      before { organisation.update!(ai_enabled: false) }

      it 'returns :ai_disabled without touching the seam' do
        expect(Lalabase::Llm::Factory).not_to receive(:for_feature)

        result = service.call

        expect(result.status).to eq(:ai_disabled)
        expect(result).not_to be_success
      end
    end

    context 'without a valid AI configuration' do
      before do
        allow(organisation).to receive(:ai_available_for?)
          .with(:ticket_summary).and_return(unavailable(:no_credential))
      end

      it 'returns :no_api_key without touching the seam' do
        expect(Lalabase::Llm::Factory).not_to receive(:for_feature)

        result = service.call

        expect(result.status).to eq(:no_api_key)
        expect(ticket.reload.summary).to be_nil
      end
    end

    # Every OTHER unavailable reason shares the setup-modal status — written as a
    # loop over the registry's own reason list so a reason added there cannot
    # quietly fall through to a status the ticket surface cannot render.
    (Lalabase::Llm::FeatureRegistry::REASONS - [:ai_disabled]).each do |reason|
      context "when the registry answers #{reason}" do
        before do
          allow(organisation).to receive(:ai_available_for?)
            .with(:ticket_summary).and_return(unavailable(reason))
        end

        it 'returns :no_api_key — one setup modal, not a status per reason' do
          expect(service.call.status).to eq(:no_api_key)
        end
      end
    end

    # Same two states again, but WITHOUT stubbing the gate — the pair above
    # proves the mapping, this one proves the real org data still reaches each
    # branch (an unconditionally-true gate would pass the pair above).
    context 'with real organisation state instead of a stubbed gate' do
      before { allow(AiCredential).to receive(:active_for_provider).and_return(nil) }

      # RELOADED between the two halves, deliberately: ai_available_for? memoises
      # per instance (organisation.rb, the #368 lesson), so re-asking the same
      # object after an update would answer from the memo and this example would
      # pass on a stale answer. Production reads one org instance per request.
      it 'reports :ai_disabled for AI off, :no_api_key for AI on but unconfigured' do
        organisation.update!(ai_enabled: false, ai_access_token: nil)
        expect(service.call.status).to eq(:ai_disabled)

        organisation.update!(ai_enabled: true)
        reloaded = described_class.new(ticket: ticket, organisation: Organisation.find(organisation.id),
                                       updater: user)
        expect(reloaded.call.status).to eq(:no_api_key)
      end
    end

    context 'when no provider can be resolved (missing credential)' do
      before do
        allow(organisation).to receive(:ai_available_for?).with(:ticket_summary).and_return(available)
        allow(Lalabase::Llm::Factory).to receive(:for_feature)
          .with(:ticket_summary, organisation)
          .and_raise(Lalabase::Llm::Factory::MissingCredentialError, 'no credential')
      end

      it 'returns :not_configured' do
        expect(service.call.status).to eq(:not_configured)
        expect(ticket.reload.summary).to be_nil
      end
    end

    context 'on success' do
      let(:provider) { provider_returning('Neue Zusammenfassung der Lage.') }

      before { stub_provider(provider) }

      it 'persists summary and updater and returns success' do
        result = service.call

        expect(result).to be_success
        expect(ticket.reload.summary).to eq('Neue Zusammenfassung der Lage.')
        expect(ticket.updater).to eq(user)
      end

      it 'builds the prompt from ticket content and conversation posts' do
        service.call

        expect(provider).to have_received(:chat) do |messages:, **|
          prompt = messages.first[:content]
          expect(prompt).to start_with('Wir haben folgende Ausgangsaussage: ')
          expect(prompt).to include('Login ist langsam.')
          expect(prompt).to include("#{user.full_name}: Ursache gefunden: N+1 Query.")
          expect(prompt).to include("Überschrift 'Modifikation'")
          # S2 moved the ONLY behavioural provider_option (presence_penalty: 0.6)
          # into the prompt, because a vendor knob works at one provider while a
          # sentence works at all of them. Without this line that trade rests on an
          # unguarded string: deleting it left the whole file green (review to #391).
          expect(prompt).to include('Vermeide doppelte Informationen')
        end
      end

      # Replaces "requests the task-specific model with the pinned parameters".
      # The model is now resolved by the factory precedence (org.preferred_chat_model
      # > credential.default_model > provider constant); passing one from here would
      # be a runtime 404 at any non-OpenAI endpoint (plan §5 falle 1).
      it 'passes NO model — the org/credential decides which model answers' do
        service.call

        expect(provider).to have_received(:chat) { |args| expect(args).not_to have_key(:model) }
      end

      # provider_options is merged verbatim into the vendor request, so top_p /
      # frequency_penalty / presence_penalty would reach Anthropic and Gemini as
      # unknown fields (400) — the same defect as the model literal, one status
      # code up. Two of the three were OpenAI defaults; the third was behavioural
      # and is deliberately given up (S1 made the same trade in its two paths).
      it 'sends no OpenAI-dialect provider_options' do
        service.call

        expect(provider).to have_received(:chat) { |args| expect(args).not_to have_key(:provider_options) }
      end

      # LITERALS, not the constants: `max_tokens: described_class::MAX_TOKENS`
      # compares a constant with itself and stays green when its VALUE changes
      # (measured in the review to #391: 500 -> 42 and 0.7 -> 0.1 broke nothing).
      # main asserted eq(500)/eq(0.7) here, so the constants would have been a
      # REGRESSION in guard strength, dressed up as a refactor.
      it 'keeps the provider-neutral task parameters' do
        service.call

        expect(provider).to have_received(:chat) do |args|
          expect(args).to include(max_tokens: 500, temperature: 0.7)
        end
      end

      it 'records usage for the call' do
        allow(Lalabase::Llm::UsageTracking).to receive(:record).and_call_original
        expect { service.call }.to change(AiUsage, :count).by(1)
      end
    end

    context 'when the API key is rejected (provider maps 401 to AuthError)' do
      before do
        provider = instance_double(Lalabase::Llm::OpenAiProvider, billing_credential: nil, provider_name: 'openai')
        allow(provider).to receive(:chat).and_raise(Lalabase::Llm::Provider::AuthError, 'invalid key')
        stub_provider(provider)
      end

      it 'returns :invalid_key and does not persist a summary' do
        expect(service.call.status).to eq(:invalid_key)
        expect(ticket.reload.summary).to be_nil
      end
    end

    context 'when the request fails unexpectedly' do
      before do
        provider = instance_double(Lalabase::Llm::OpenAiProvider, billing_credential: nil, provider_name: 'openai')
        allow(provider).to receive(:chat).and_raise(StandardError, 'boom')
        stub_provider(provider)
      end

      it 'returns :error and does not persist a summary' do
        expect(service.call.status).to eq(:error)
        expect(ticket.reload.summary).to be_nil
      end
    end

    context 'when saving the ticket fails' do
      before do
        stub_provider(provider_returning('Zusammenfassung'))
        allow(ticket).to receive(:save).and_return(false)
      end

      it 'returns :save_failed' do
        expect(service.call.status).to eq(:save_failed)
      end
    end

    # The heart of S2: NOT stubbed at the Factory and NOT stubbed at the gate, so
    # the real chain (org.ai_provider -> gate -> PROVIDER_CLASSES -> credentials)
    # runs. Only the provider CLASS is spied, which keeps the HTTP client out
    # without hiding the routing decision.
    describe 'provider routing follows the org choice (S2)' do
      let(:provider) { provider_returning('Neue Zusammenfassung der Lage.') }

      before do
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

        # The defect S2 closes: before it, this org's ticket AND every post on it
        # went to OpenAI, whatever its admin had chosen.
        it 'builds the org-compatible provider, never OpenAI' do
          expect(service.call).to be_success

          expect(Lalabase::Llm::OpenAiCompatibleProvider).to have_received(:new)
          expect(Lalabase::Llm::OpenAiProvider).not_to have_received(:new)
          expect(ticket.reload.summary).to eq('Neue Zusammenfassung der Lage.')
        end

        it 'sends no model literal — a gpt-4o-mini here is a runtime 404 at the endpoint' do
          service.call

          expect(provider).to have_received(:chat) do |args|
            expect(args).not_to have_key(:model)
            expect(args).to include(max_tokens: 500, temperature: 0.7)
          end
        end

        # Falle 4 of the plan: the provider swap must not move the attribution,
        # or the cost leaves the quota seam. Same call_type, same registry action.
        it 'keeps the metering attribution unchanged' do
          expect(Lalabase::Llm::UsageTracking).to receive(:record).with(
            hash_including(organisation: organisation, call_type: 'ticket_summary',
                           action: Lalabase::Llm::ActionRegistry::SUMMARY,
                           subject: ticket, user: user)
          )

          service.call
        end

        it 'passes the gate that used to ask for openai' do
          expect(organisation.ai_available_for?(:ticket_summary)).to be_available
          expect(organisation.has_valid_ai_configuration?('openai')).to be(false)
        end
      end

      # Regression for an org that never made a choice (ai_provider default
      # 'openai'): the ROUTING is unchanged — same provider class, same credential
      # resolution, same summary.
      context 'with an org without an own choice (default openai)' do
        context 'on a BYOK token without a preferred model' do
          before { organisation.update!(ai_provider: 'openai', ai_access_token: 'sk-org-own-1234567890') }

          it 'routes to OpenAI with no configured model — i.e. the old gpt-4o-mini literal' do
            expect(service.call).to be_success

            expect(Lalabase::Llm::OpenAiProvider).to have_received(:new).with(hash_including(chat_model: nil))
            expect(Lalabase::Llm::OpenAiCompatibleProvider).not_to have_received(:new)
            # chat_model: nil -> OpenAiProvider#default_chat_model -> DEFAULT_CHAT_MODEL,
            # which is exactly the model this service used to pass by hand.
            expect(Lalabase::Llm::OpenAiProvider::DEFAULT_CHAT_MODEL).to eq('gpt-4o-mini')
            expect(ticket.reload.summary).to eq('Neue Zusammenfassung der Lage.')
          end
        end

        # E2 of the plan, accepted consequence: on the SYSTEM credential the model
        # is no longer the hand-passed literal but the credential's default_model.
        # Pinned deliberately — this is the one behavioural change of S2 for orgs
        # that never touched a setting, and it must not happen unnoticed.
        context 'on the system credential' do
          before { create(:ai_credential, :active, provider: 'openai', default_model: 'gpt-4o') }

          it 'routes to OpenAI and inherits the credential model (E2)' do
            expect(service.call).to be_success

            expect(Lalabase::Llm::OpenAiProvider).to have_received(:new).with(hash_including(chat_model: 'gpt-4o'))
            expect(Lalabase::Llm::OpenAiCompatibleProvider).not_to have_received(:new)
          end
        end
      end
    end
  end

  # KI-Pakete P3, the MAJOR finding of the adversarial verify pass — reproduced in
  # both directions before the fix and pinned here against the PRODUCTION path
  # (the service, not the registry).
  #
  # :ticket_summary is a utility row: it routes on the package's cheapest rung,
  # whatever rung the org picked for chat. The gate used to derive the org's OWN
  # rung, so with the two rungs on different credentials it answered about a
  # credential the request never touches — and it was wrong in BOTH directions,
  # which is why neither direction alone would have caught it.
  describe 'the gate follows the rung the summary routes on' do
    let(:fast_credential) do
      create(:ai_credential, :openai_compatible, :eu_company, name: 'Mistral FR small',
                                                              default_model: 'mistral-small-latest',
                                                              access_token: 'mistral-fast-token-123456')
    end
    let(:thorough_credential) do
      create(:ai_credential, :openai_compatible, :eu_company, name: 'Mistral FR large',
                                                              default_model: 'mistral-large-latest',
                                                              access_token: 'mistral-large-token-1234')
    end
    let(:embedding_credential) do
      create(:ai_credential, :openai_compatible, :embedding_only, :eu_company,
             name: 'Mistral FR embed', default_model: 'mistral-embed',
             access_token: 'mistral-embed-token-123')
    end

    let(:package) do
      package = create(:ai_package, name: 'Europäisch (zwei Stufen)',
                                    embedding_credential: embedding_credential,
                                    embedding_model: 'mistral-embed', embedding_dims: 1024)
      package.tiers.create!(key: 'fast', label: 'Schnell & günstig', position: 0,
                            chat_credential: fast_credential)
      package.tiers.create!(key: 'thorough', label: 'Gründlich', position: 1,
                            chat_credential: thorough_credential)
      package
    end

    # THOROUGH, because on the fast rung both gates answer alike and neither
    # direction below is observable.
    before { organisation.update!(ai_enabled: true, ai_package: package, ai_package_tier_key: 'thorough') }

    it 'withholds the summary when the rung it USES is broken' do
      fast_credential.update_columns(enabled: false)

      expect(service.call.status).to eq(:no_api_key)
    end

    # The direction that made this a MAJOR rather than a cosmetic mismatch: the
    # old gate refused a summary that would have worked perfectly.
    it 'still offers the summary when only the org rung is broken' do
      thorough_credential.update_columns(enabled: false)
      allow(Lalabase::Llm::OpenAiCompatibleProvider).to receive(:new).and_return(
        provider_returning('Neue Zusammenfassung der Lage.')
      )

      expect(service.call).to be_success
      expect(ticket.reload.summary).to eq('Neue Zusammenfassung der Lage.')
    end
  end
end
