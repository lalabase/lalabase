# frozen_string_literal: true

require 'rails_helper'

# What: Request spec for the Vertex model-availability matrix (admin surface).
# Why: The POST endpoint must stay behind the beuser session, accept only
#   google credentials, always force-refresh the probe, and surface probe/auth
#   failures as flash alerts. The show page renders matrix, legend and empty
#   state purely from the cache — a GET must never trigger a probe. The probe
#   service is stubbed throughout: no network call ever leaves the suite.
RSpec.describe 'Admin::AiCredentials vertex availability', type: :request do
  let(:admin_beuser) { create(:beuser) } # role 'admin'
  let(:credential) { create(:admin_ai_credential, :google) }

  def log_in_admin
    post admin_log_in_path, params: { email: admin_beuser.email, password: admin_beuser.password }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  # A minimal matrix covering all four cell colours (green 200, green-400
  # embedding, red 404, yellow 5xx) plus the info-only global row.
  def sample_matrix
    {
      checked_at: Time.zone.local(2026, 7, 18, 9, 30),
      project_id: 'lala-eu',
      regions: %w[europe-west3 global],
      models: %w[gemini-2.5-flash gemini-embedding-001],
      results: [
        { region: 'europe-west3', model: 'gemini-2.5-flash', status_code: 200, available: true, info_only: false },
        { region: 'europe-west3', model: 'gemini-embedding-001', status_code: 400, available: true, info_only: false },
        { region: 'global', model: 'gemini-2.5-flash', status_code: 404, available: false, info_only: true },
        { region: 'global', model: 'gemini-embedding-001', status_code: 500, available: false, info_only: true }
      ]
    }
  end

  describe 'POST /admin/ai_credentials/:id/vertex_availability' do
    it 'force-refreshes the probe and redirects with a notice' do
      allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:call).and_return(sample_matrix)
      log_in_admin

      post vertex_availability_admin_ai_credential_path(credential)

      expect(Lalabase::Llm::VertexAvailabilityProbe)
        .to have_received(:call).with(credential_id: credential.id, force_refresh: true)
      expect(response).to redirect_to(admin_ai_credential_path(credential))
      expect(flash[:notice]).to eq(I18n.t('flash.admin.ai_credentials.vertex_availability_checked'))
    end

    it 'redirects to the admin login without a beuser session (probe untouched)' do
      allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:call)

      post vertex_availability_admin_ai_credential_path(credential)

      expect(response).to redirect_to(admin_log_in_path)
      expect(Lalabase::Llm::VertexAvailabilityProbe).not_to have_received(:call)
    end

    it 'rejects a non-google credential with an alert, probe untouched' do
      openai = create(:admin_ai_credential) # provider 'openai'
      allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:call)
      log_in_admin

      post vertex_availability_admin_ai_credential_path(openai)

      expect(response).to redirect_to(admin_ai_credential_path(openai))
      expect(flash[:alert]).to eq(I18n.t('flash.admin.ai_credentials.vertex_availability_unsupported'))
      expect(Lalabase::Llm::VertexAvailabilityProbe).not_to have_received(:call)
    end

    it 'surfaces a ProbeError as a flash alert' do
      allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:call)
        .and_raise(Lalabase::Llm::VertexAvailabilityProbe::ProbeError, 'credential has no service-account JSON')
      log_in_admin

      post vertex_availability_admin_ai_credential_path(credential)

      expect(response).to redirect_to(admin_ai_credential_path(credential))
      expect(flash[:alert]).to include('credential has no service-account JSON')
    end

    it 'surfaces a failed token mint (AuthError) as a flash alert' do
      allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:call)
        .and_raise(Lalabase::Llm::Provider::AuthError, 'google token mint failed: invalid_grant')
      log_in_admin

      post vertex_availability_admin_ai_credential_path(credential)

      expect(response).to redirect_to(admin_ai_credential_path(credential))
      expect(flash[:alert]).to include('google token mint failed')
    end
  end

  describe 'GET /admin/ai_credentials/:id (matrix card)' do
    it 'renders matrix cells, legend, timestamp and refresh button from the cache' do
      allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:cached).and_return(sample_matrix)
      log_in_admin

      get admin_ai_credential_path(credential)

      expect(response).to have_http_status(:ok)
      expect(Lalabase::Llm::VertexAvailabilityProbe)
        .to have_received(:cached).with(credential_id: credential.id)
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.show.availability_title'))
      expect(response.body).to include('gemini-2.5-flash')
      expect(response.body).to include('gemini-embedding-001')
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.show.availability_cell_unavailable'))
      # the yellow 5xx cell carries its raw status code
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.show.availability_cell_status', code: 500))
      # the green-400 embedding cell keeps the raw code in its tooltip
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.show.availability_cell_status', code: 400))
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.show.availability_global_badge'))
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.show.availability_legend_available'))
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.show.availability_legend_unavailable'))
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.show.availability_legend_error'))
      expect(response.body).to include('18.07.2026 09:30')
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.show.availability_btn_refresh'))
      expect(response.body).not_to include('translation missing')
    end

    it 'renders the empty state with the check button when nothing is cached' do
      allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:cached).and_return(nil)
      log_in_admin

      get admin_ai_credential_path(credential)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.show.availability_empty'))
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.show.availability_btn_check'))
      # Regression guard: the trigger must be a native POST form (button_to), not
      # a link_to+turbo_method — rails-ujs is disabled and data-turbo-method is
      # unreliable in the admin area, so only a real form reliably POSTs.
      expect(response.body)
        .to match(/<form[^>]+action="#{Regexp.escape(vertex_availability_admin_ai_credential_path(credential))}"[^>]*>/i)
      expect(response.body).to match(/<form[^>]+method="post"/i)
      expect(response.body).not_to include('translation missing')
    end

    it 'shows the missing-project hint instead of the button when project_id is absent' do
      credential.update_column(:additional_config, { 'location' => 'europe-west3' })
      allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:cached).and_return(nil)
      log_in_admin

      get admin_ai_credential_path(credential)

      # ERB escapes the apostrophes of additional_config['project_id'] in the body
      expect(response.body)
        .to include(ERB::Util.html_escape(I18n.t('views.admin.ai_credentials.show.availability_missing_project')))
      expect(response.body).not_to include(I18n.t('views.admin.ai_credentials.show.availability_btn_check'))
    end

    it 'does not render the card for non-google credentials (no cache read either)' do
      openai = create(:admin_ai_credential)
      allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:cached)
      log_in_admin

      get admin_ai_credential_path(openai)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t('views.admin.ai_credentials.show.availability_title'))
      expect(Lalabase::Llm::VertexAvailabilityProbe).not_to have_received(:cached)
    end
  end
end
