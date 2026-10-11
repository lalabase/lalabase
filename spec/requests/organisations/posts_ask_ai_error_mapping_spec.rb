# frozen_string_literal: true

# What: Request spec for the ask-AI CODE → FLASH mapping in posts#create after the
#   orchestration moved into Actors::CreateAiPost.
# Why: the six former rescue branches must still produce the SAME flash copy. The
#   actor unit spec pins code assignment; this pins the controller's
#   ai_post_error_flash mapping end-to-end (and the happy path writing an AI post).
# Contract: user post is ALWAYS saved; AI failure only sets an alert; the flash text
#   equals the pre-refactor copy for every failure class.

require 'rails_helper'

RSpec.describe 'Organisations::Posts ask_ai code→flash mapping', type: :request do
  let(:organisation) { create(:organisation) } # ai_enabled defaults to true in factories
  let(:user) { create(:user) }
  let(:role) { ActsAsTenant.with_tenant(organisation) { create(:admin_role, organisation: organisation) } }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user)
    end
  end

  let(:provider) { instance_double(Lalabase::Llm::OpenAiProvider) }
  let(:chat_result) { { content: '<strong>AI</strong>', token_usage: { total_tokens: 10 }, model_used: 'gpt-4o-mini' } }

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
    Current.user = user
    allow(Lalabase::Llm::UsageTracking).to receive(:record)
  end

  after { Current.reset }

  def ask_ai
    post organisation_project_ticket_posts_path(organisation, project, ticket),
         params: { post: { content: 'Please summarise' }, ask_ai: '1' }
  end

  def post_count
    ActsAsTenant.with_tenant(organisation) { ticket.posts.count }
  end

  context 'happy path (AI enabled + AI user present)' do
    let!(:ai_user) { create(:user, is_ai: true) }

    before do
      allow(Lalabase::Llm::Factory).to receive(:build).and_return(provider)
      allow(provider).to receive(:chat).and_return(chat_result)
    end

    it 'saves the user post AND an AI reply, with no alert' do
      expect { ask_ai }.to change { post_count }.by(2)
      expect(flash[:alert]).to be_blank
    end
  end

  context 'provider failures map to the existing flash copy' do
    let!(:ai_user) { create(:user, is_ai: true) }

    it 'AiDisabledError → disabled_member_hint (only the user post is saved)' do
      allow(Lalabase::Llm::Factory).to receive(:build).and_raise(Lalabase::Llm::AiDisabledError.new('off'))
      expect { ask_ai }.to change { post_count }.by(1)
      expect(flash[:alert]).to eq(I18n.t('shared.ai.disabled_member_hint'))
    end

    it 'QuotaExceededError → quota_exhausted_member_hint' do
      allow(Lalabase::Llm::Factory).to receive(:build).and_raise(Lalabase::Llm::QuotaExceededError.new('q'))
      ask_ai
      expect(flash[:alert]).to eq(I18n.t('shared.ai.quota_exhausted_member_hint'))
    end

    it 'MissingCredentialError → ai_not_configured' do
      allow(Lalabase::Llm::Factory).to receive(:build)
        .and_raise(Lalabase::Llm::Factory::MissingCredentialError.new('no cred'))
      ask_ai
      expect(flash[:alert]).to eq(I18n.t('flash.posts.ai_not_configured'))
    end

    it 'chat AuthError → ai_invalid_key' do
      allow(Lalabase::Llm::Factory).to receive(:build).and_return(provider)
      allow(provider).to receive(:chat).and_raise(Lalabase::Llm::Provider::AuthError.new('401'))
      ask_ai
      expect(flash[:alert]).to eq(I18n.t('flash.posts.ai_invalid_key'))
    end

    it 'chat Faraday::ClientError → ai_error with the message interpolated' do
      allow(Lalabase::Llm::Factory).to receive(:build).and_return(provider)
      allow(provider).to receive(:chat).and_raise(Faraday::ClientError.new('boom 502'))
      ask_ai
      expect(flash[:alert]).to eq(I18n.t('flash.posts.ai_error', error: 'boom 502'))
    end
  end

  context 'missing AI user → generic fallback' do
    before do
      # No is_ai user in the DB.
      allow(Lalabase::Llm::Factory).to receive(:build).and_return(provider)
      allow(provider).to receive(:chat).and_return(chat_result)
    end

    it 'ai_fallback (user post still saved, no AI post)' do
      expect { ask_ai }.to change { post_count }.by(1)
      expect(flash[:alert]).to eq(I18n.t('flash.posts.ai_fallback'))
    end
  end
end
