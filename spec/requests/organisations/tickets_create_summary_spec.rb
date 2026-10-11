# frozen_string_literal: true

require 'rails_helper'

# Behaviour guards for POST create_summary (AI ticket summary).
# This spec pins the action's end-to-end behaviour across all outcomes
# (no API key, missing credential, success, invalid key, API error, save error).
# S2 / KI-Pakete P3: the AI seam is the :ticket_summary registry row — the gate
# (Organisation#ai_available_for?, which reads has_valid_ai_configuration? for the
# rung it routes on) and Lalabase::Llm::Factory.for_feature → a Provider whose
# #chat yields the normalised {content:, token_usage:, ...} hash. The stubs below
# constrain the PROVIDER and leave the trailing kwargs open (`any_args`): the rung
# travels there, and pinning the exact argument list would break this file on
# every gate the rendered page adds.
RSpec.describe 'Tickets create_summary', type: :request do
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

  let(:turbo_headers) { { 'Accept' => 'text/vnd.turbo-stream.html' } }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    sign_in user
  end

  def post_create_summary(headers: turbo_headers)
    post create_summary_organisation_project_ticket_path(organisation, project, ticket), headers: headers
  end

  def stub_provider(provider)
    # `any_args` after the provider, not instead of it: the PROVIDER is what this
    # stub asserts, while the trailing kwargs are the caller's business. Since
    # KI-Pakete P3 the registry passes `utility:` here (the rung a feature routes
    # on), and the rendered page asks about several features at once — pinning
    # the exact argument list would make this helper break on every gate the view
    # happens to add.
    allow_any_instance_of(Organisation)
      .to receive(:has_valid_ai_configuration?).with('openai', any_args).and_return(true)
    allow(Lalabase::Llm::Factory).to receive(:build).and_return(provider)
  end

  def successful_provider(summary_text)
    instance_double(Lalabase::Llm::OpenAiProvider, billing_credential: nil, provider_name: 'openai').tap do |provider|
      allow(provider).to receive(:chat).and_return(
        content: summary_text, model_used: 'gpt-4o-mini',
        token_usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 }
      )
    end
  end

  context 'without a valid AI configuration' do
    before do
      allow_any_instance_of(Organisation).to receive(:has_valid_ai_configuration?).with('openai', any_args).and_return(false)
    end

    it 'shows the missing-api-key alert as turbo stream and leaves the summary untouched' do
      post_create_summary

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('flash.tickets.ai_no_api_key'))
      expect(ticket.reload.summary).to be_nil
    end

    it 'redirects with the missing-api-key alert for html requests' do
      post_create_summary(headers: {})

      expect(response).to redirect_to(organisation_project_tickets_path(organisation, project))
      expect(flash[:alert]).to eq(I18n.t('flash.tickets.ai_no_api_key'))
    end
  end

  context 'when no provider can be resolved (missing credential)' do
    before do
      allow_any_instance_of(Organisation).to receive(:has_valid_ai_configuration?).with('openai', any_args).and_return(true)
      allow(Lalabase::Llm::Factory).to receive(:build)
        .and_raise(Lalabase::Llm::Factory::MissingCredentialError, 'no credential')
    end

    it 'redirects with the not-configured alert' do
      post_create_summary(headers: {})

      expect(response).to redirect_to(organisation_project_tickets_path(organisation, project))
      expect(flash[:alert]).to eq(I18n.t('flash.tickets.ai_not_configured'))
      expect(ticket.reload.summary).to be_nil
    end
  end

  context 'when the AI request succeeds' do
    before { stub_provider(successful_provider('Neue Zusammenfassung der Lage.')) }

    it 'persists summary and updater and streams frame update, row replace and success flash' do
      post_create_summary

      expect(response).to have_http_status(:ok)
      expect(ticket.reload.summary).to eq('Neue Zusammenfassung der Lage.')
      expect(ticket.updater).to eq(user)
      expect(response.body).to include('ticket_display_frame')
      expect(response.body).to include("tr[data-ticket-id=&#39;#{ticket.id}&#39;]")
      expect(response.body).to include(I18n.t('flash.tickets.summary_created'))
    end

    it 'redirects with success notice for html requests' do
      post_create_summary(headers: {})

      expect(response).to redirect_to(
        organisation_project_tickets_path(organisation, project, ticket_id: ticket.id)
      )
      expect(flash[:notice]).to eq(I18n.t('flash.tickets.summary_created'))
    end

    it 'sends ticket content and the conversation posts to the provider' do
      provider = successful_provider('Zusammenfassung')
      stub_provider(provider)

      post_create_summary

      expect(provider).to have_received(:chat) do |messages:, **|
        prompt = messages.first[:content]
        expect(prompt).to include('Login ist langsam.')
        expect(prompt).to include('Ursache gefunden: N+1 Query.')
        expect(prompt).to include(user.full_name)
      end
    end
  end

  context 'when the API key is rejected (provider maps 401 to AuthError)' do
    before do
      provider = instance_double(Lalabase::Llm::OpenAiProvider, billing_credential: nil, provider_name: 'openai')
      allow(provider).to receive(:chat).and_raise(Lalabase::Llm::Provider::AuthError, 'invalid key')
      stub_provider(provider)
    end

    it 'shows the invalid-key alert and does not persist a summary' do
      post_create_summary

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('flash.tickets.ai_invalid_key'))
      expect(ticket.reload.summary).to be_nil
    end

    it 'redirects with the invalid-key alert for html requests' do
      post_create_summary(headers: {})

      expect(response).to redirect_to(organisation_project_tickets_path(organisation, project))
      expect(flash[:alert]).to eq(I18n.t('flash.tickets.ai_invalid_key'))
    end
  end

  context 'when the AI request fails unexpectedly' do
    before do
      provider = instance_double(Lalabase::Llm::OpenAiProvider, billing_credential: nil, provider_name: 'openai')
      allow(provider).to receive(:chat).and_raise(StandardError, 'boom')
      stub_provider(provider)
    end

    it 'shows the generic AI error alert and does not persist a summary' do
      post_create_summary

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('flash.tickets.ai_error'))
      expect(ticket.reload.summary).to be_nil
    end
  end

  context 'when saving the ticket fails' do
    before do
      stub_provider(successful_provider('Neue Zusammenfassung'))
      allow_any_instance_of(Ticket).to receive(:save).and_return(false)
    end

    it 'shows the summary error alert' do
      post_create_summary

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('flash.tickets.summary_error'))
    end
  end

  context 'without ticket write permission' do
    let(:user) { create(:user) }

    before do
      allow_any_instance_of(ProjectPolicy).to receive(:area_access?) do |_policy, area, level|
        !(area == :tickets && level == :write)
      end
    end

    it 'redirects to the project before any AI call' do
      expect(Lalabase::Llm::Factory).not_to receive(:build)

      post_create_summary(headers: {})

      expect(response).to redirect_to(organisation_project_path(organisation, project))
      expect(flash[:alert]).to be_present
      expect(ticket.reload.summary).to be_nil
    end
  end
end
