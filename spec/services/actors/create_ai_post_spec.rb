# frozen_string_literal: true

# spec/services/actors/create_ai_post_spec.rb
#
# What: unit spec for the CreateAiPost actor — the "Ask AI" side path lifted out of
#   posts#create. The provider is mocked; we pin the mapping from each provider
#   failure to a machine-readable code the controller turns into flash copy.
# Why: this is a Tier-2 actor (LLM call outside a txn). The contract that matters:
#   every failure class becomes the RIGHT code, a missing AI user is a failure (not a
#   silent log), and a successful call writes ONE post as the global is_ai user +
#   meters usage.

require 'rails_helper'

RSpec.describe Actors::CreateAiPost, type: :service do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation, creator: user) }
  let!(:ai_user) { create(:user, is_ai: true) }

  let(:provider) { instance_double(Lalabase::Llm::OpenAiProvider) }
  let(:chat_result) do
    { content: '<strong>AI answer</strong>', token_usage: { total_tokens: 42 }, model_used: 'gpt-4o-mini' }
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
    allow(Lalabase::Llm::UsageTracking).to receive(:record)
  end

  def call
    described_class.call(ticket: ticket, current_user: user, organisation: organisation)
  end

  describe '#call — success' do
    before do
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_call_original
      allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:ask_ai_post, anything).and_return(provider)
      allow(provider).to receive(:chat).and_return(chat_result)
    end

    it 'returns a successful Result' do
      expect(call).to be_success
    end

    it 'creates exactly one AI post authored by the global is_ai user' do
      expect { call }.to change(Post, :count).by(1)
      post = Post.order(:created_at).last
      expect(post.user).to eq(ai_user)
      expect(post.ticket).to eq(ticket)
      expect(post.content.to_plain_text).to include('AI answer')
    end

    it 'exposes the created post as the record' do
      result = call
      expect(result.resource).to be_a(Post)
      expect(result.resource.user).to eq(ai_user)
    end

    it 'meters usage through the gated seam (POST_AI action, ticket subject)' do
      call
      expect(Lalabase::Llm::UsageTracking).to have_received(:record).with(
        hash_including(
          organisation: organisation, provider: provider,
          action: Lalabase::Llm::ActionRegistry::POST_AI, subject: ticket, user: user
        )
      )
    end

    # Replaces "calls the provider pinned to gpt-4o-mini". The model is now
    # resolved by the factory precedence (org.preferred_chat_model >
    # credential.default_model > provider constant); passing one from here would
    # be a runtime 404 at any non-OpenAI endpoint (plan §5 falle 1). Same for
    # provider_options: merged verbatim into the vendor request, so the three
    # OpenAI knobs would reach Anthropic / Gemini as unknown fields (400).
    it 'passes neither a model nor OpenAI-dialect provider_options' do
      call

      expect(provider).to have_received(:chat) do |args|
        expect(args).not_to have_key(:model)
        expect(args).not_to have_key(:provider_options)
        # Literals on purpose — the constants would compare with themselves and
        # survive a value change (review to #391).
        expect(args).to include(max_tokens: 500, temperature: 0.7)
      end
    end
  end

  # The heart of S2 for P4: NOT stubbed at the Factory, so the real resolution
  # (org.ai_provider -> gate -> PROVIDER_CLASSES -> credentials) runs. Only the
  # provider CLASS is spied, which keeps the HTTP client out without hiding the
  # routing decision.
  describe '#call — provider routing follows the org choice (S2)' do
    before do
      allow(Lalabase::Llm::OpenAiProvider).to receive(:new).and_return(provider)
      allow(Lalabase::Llm::OpenAiCompatibleProvider).to receive(:new).and_return(provider)
      allow(provider).to receive(:chat).and_return(chat_result)
    end

    context 'with an org on an openai_compatible endpoint (e.g. Mistral EU, BYOK)' do
      let(:organisation) do
        create(:organisation, ai_enabled: true, ai_provider: 'openai_compatible',
                              ai_access_token: 'sk-mistral-own-token-1234567890',
                              ai_api_base: 'https://api.mistral.ai/v1',
                              preferred_chat_model: 'mistral-small-latest')
      end

      # The defect S2 closes: before it, the ticket, its whole conversation and
      # every project note went to OpenAI, whatever the org's admin had chosen.
      it 'builds the org-compatible provider, never OpenAI' do
        expect(call).to be_success

        expect(Lalabase::Llm::OpenAiCompatibleProvider).to have_received(:new)
        expect(Lalabase::Llm::OpenAiProvider).not_to have_received(:new)
      end

      it 'sends no model literal — a gpt-4o-mini here is a runtime 404 at the endpoint' do
        call

        expect(provider).to have_received(:chat) { |args| expect(args).not_to have_key(:model) }
      end

      # Falle 4 of the plan: the provider swap must not move the attribution, or
      # the cost leaves the quota seam. Same call_type, same registry action.
      #
      # LITERAL, not described_class::CALL_TYPE: comparing the constant with
      # itself is a tautology — renaming its VALUE would keep this green (measured
      # in the review to #391: 'ask_ai' -> 'ask_ai_MUT' left 37 examples passing).
      # The point of this example is that the attribution VALUE stays what the
      # reporting expects, so the value has to be written out.
      it 'keeps the metering attribution unchanged' do
        call

        expect(Lalabase::Llm::UsageTracking).to have_received(:record).with(
          hash_including(organisation: organisation, call_type: 'ask_ai',
                         action: Lalabase::Llm::ActionRegistry::POST_AI, subject: ticket, user: user)
        )
      end
    end

    # Regression for an org that never made a choice (ai_provider default
    # 'openai'): same provider class, same credential resolution, same post.
    context 'with an org without an own choice (default openai)' do
      before { organisation.update!(ai_provider: 'openai', ai_access_token: 'sk-org-own-1234567890') }

      it 'routes to OpenAI with no configured model — i.e. the old gpt-4o-mini literal' do
        expect { expect(call).to be_success }.to change(Post, :count).by(1)

        expect(Lalabase::Llm::OpenAiProvider).to have_received(:new).with(hash_including(chat_model: nil))
        expect(Lalabase::Llm::OpenAiCompatibleProvider).not_to have_received(:new)
        # chat_model: nil -> OpenAiProvider#default_chat_model -> DEFAULT_CHAT_MODEL,
        # which is exactly the model this actor used to pass by hand.
        expect(Lalabase::Llm::OpenAiProvider::DEFAULT_CHAT_MODEL).to eq('gpt-4o-mini')
      end
    end
  end

  describe '#call — empty LLM content' do
    before do
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_call_original
      allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:ask_ai_post, anything).and_return(provider)
      allow(provider).to receive(:chat).and_return(chat_result.merge(content: ''))
    end

    it 'creates no post but still succeeds' do
      expect { call }.not_to change(Post, :count)
      expect(call).to be_success
    end
  end

  describe '#call — no AI user configured' do
    before do
      ai_user.destroy
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_call_original
      allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:ask_ai_post, anything).and_return(provider)
      allow(provider).to receive(:chat).and_return(chat_result)
    end

    it 'fails with :internal_error and writes no post' do
      expect { @result = call }.not_to change(Post, :count)
      expect(@result).not_to be_success
      expect(@result.code).to eq(:internal_error)
    end
  end

  describe '#call — provider failures mapped to codes' do
    def expect_failure_code(error, code)
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_call_original
      allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:ask_ai_post, anything).and_raise(error)
      result = call
      expect(result).not_to be_success
      expect(result.code).to eq(code)
    end

    it 'maps AiDisabledError → :ai_disabled' do
      expect_failure_code(Lalabase::Llm::AiDisabledError.new('off'), :ai_disabled)
    end

    it 'maps QuotaExceededError → :quota_exceeded' do
      expect_failure_code(Lalabase::Llm::QuotaExceededError.new('quota'), :quota_exceeded)
    end

    it 'maps Factory::MissingCredentialError → :not_configured' do
      expect_failure_code(Lalabase::Llm::Factory::MissingCredentialError.new('no cred'), :not_configured)
    end

    it 'maps a chat AuthError → :invalid_key' do
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_call_original
      allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:ask_ai_post, anything).and_return(provider)
      allow(provider).to receive(:chat).and_raise(Lalabase::Llm::Provider::AuthError.new('401'))
      result = call
      expect(result.code).to eq(:invalid_key)
    end

    it 'maps a chat Faraday::ClientError → :provider_error and preserves the message' do
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_call_original
      allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:ask_ai_post, anything).and_return(provider)
      allow(provider).to receive(:chat).and_raise(Faraday::ClientError.new('boom 502'))
      result = call
      expect(result.code).to eq(:provider_error)
      expect(result.errors.first).to include('boom 502')
    end

    # The providers map a vendor 400 to RequestRefusedError (a Provider::Error,
    # no longer a Faraday::ClientError). It must stay the handled provider error,
    # not fall through to :internal_error (or raise in development and test).
    it 'maps a chat RequestRefusedError → :provider_error and preserves the message' do
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_call_original
      allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:ask_ai_post, anything).and_return(provider)
      allow(provider).to receive(:chat).and_raise(Lalabase::Llm::Provider::RequestRefusedError.new('HTTP 400: refused'))
      result = nil
      expect { result = call }.not_to change(Post.where(ticket: ticket), :count)
      expect(result.code).to eq(:provider_error)
      expect(result.errors.first).to include('HTTP 400: refused')
    end

    it 'keeps an OpenAI 400 the handled provider error end to end (real provider, stubbed client)' do
      fake_client = instance_double(OpenAI::Client)
      allow(OpenAI::Client).to receive(:new).and_return(fake_client)
      allow(fake_client).to receive(:chat).and_raise(Faraday::BadRequestError.new('the server responded with status 400'))
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_call_original
      real_provider = Lalabase::Llm::OpenAiProvider.new(api_key: 'sk-test')
      allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:ask_ai_post, anything).and_return(real_provider)
      expect(call.code).to eq(:provider_error)
    end

    it 'writes no post on any provider failure' do
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_call_original
      allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:ask_ai_post, anything).and_raise(Lalabase::Llm::AiDisabledError.new('off'))
      expect { call }.not_to change(Post, :count)
    end
  end

  describe 'Current.user handling' do
    it 'restores the previous Current.user after a failed call (no leak)' do
      Current.user = nil
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_call_original
      allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:ask_ai_post, anything).and_raise(Lalabase::Llm::AiDisabledError.new('off'))
      call
      expect(Current.user).to be_nil
    end
  end
end
