# frozen_string_literal: true

# What: Request spec for the provider dropdown of "Eigene Konfiguration".
# Type: Request spec — S1 "honest facade" regression guard.
# Why (philosophy): Before S1 the dropdown offered every AiCredential::PROVIDERS
#   entry, including providers the Lalabase::Llm::Factory cannot build (google,
#   cohere). An org admin could select "Google (Gemini)" and the first chat then
#   failed with Provider::Error — far away from the cause. The dropdown must
#   only ever offer AiCredential.implemented_providers (derived from the
#   Factory registry), on BOTH render paths: #show and the #update failure
#   re-render (a second, easily-forgotten assignment site).
# Contract: option values ⊆ implemented_providers; cohere never appears
#   (google joined the implemented set with the GoogleVertexProvider slice).
#
# ⚠️ The dropdown MOVED with S7 (doc/ki_bereich_navigation_plan.md, E6-A): it sat in
#   the two-axis form on ai_settings#show and now lives on its own screen. The guard
#   moved with it rather than being deleted — both assignment sites still exist, they
#   are just in Organisations::AiConfigurationsController now.

require 'rails_helper'

RSpec.describe 'Organisations::AiConfigurations provider dropdown (S1 honest facade)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin) { create(:user) }

  let(:admin_role) { ActsAsTenant.with_tenant(organisation) { create(:admin_role, organisation: organisation) } }

  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
    end
  end

  before { sign_in admin }

  describe 'GET #show' do
    it 'offers only implemented providers (incl. google since Slice 3) — no cohere' do
      get organisation_ai_configuration_path(organisation)

      expect(response).to have_http_status(:ok)
      AiCredential.implemented_providers.each do |provider|
        expect(response.body).to include(%(value="#{provider}")),
                                 "expected option for implemented provider #{provider}"
      end
      expect(response.body).to include('value="google"')
      expect(response.body).not_to include('value="cohere"')
    end
  end

  describe 'PATCH #update failure re-render' do
    # The 422 branch rebuilds @provider_options independently of #show — this
    # pins the second assignment site to the same implemented-only source.
    it 'still offers only implemented providers' do
      # An unknown provider is now refused by Actors::SaveAiConfiguration
      # (:unknown_provider) instead of by the org's inclusion validation — the actor
      # asks BEFORE the write rather than letting the record answer afterwards.
      patch organisation_ai_configuration_path(organisation), params: { ai_provider: 'martian_llm' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).not_to include('value="cohere"')
      expect(response.body).to include('value="openai"')
      expect(response.body).to include('value="google"')
    end
  end
end
