# frozen_string_literal: true

require 'rails_helper'

# Request spec (not controller spec) on purpose: it exercises the real path + the
# beuser session, and avoids the controller-spec `patch :action` URL generation
# that flakes on freshly-added routes locally.
RSpec.describe 'Admin::Organisations project-chat toggle', type: :request do
  let(:admin_beuser) { create(:beuser) } # factory: role 'admin', active
  let(:organisation) { create(:organisation) } # DB default: code_indexing_enabled false

  # Establish the operator session via the real admin login (sets session[:user_id]).
  # Asserts login actually took, so a broken login fails HERE rather than later at
  # the toggle with a confusing redirect-to-login symptom.
  def log_in_admin
    post admin_log_in_path, params: { email: admin_beuser.email, password: admin_beuser.password }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  # The admin twin of a property the tenant side already guards
  # (spec/requests/organisations/ai_usage_spec.rb, "builds exactly one QuotaLedger").
  # This is the ONLY other page that renders both quota partials, so it is the only
  # other place the defect can occur — and nothing watched it, which is why the fix
  # first shipped on one side only. Each partial otherwise builds its own ledger, and
  # each of those re-runs the monthly consumption sum plus two uncached SystemSetting
  # reads.
  describe 'GET /admin/organisations/:id' do
    it 'builds exactly one QuotaLedger for both quota partials' do
      log_in_admin
      allow(Lalabase::Llm::QuotaLedger).to receive(:for).and_call_original

      get admin_organisation_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(Lalabase::Llm::QuotaLedger).to have_received(:for).once
    end
  end

  # Step 4 of doc/projekt_chat_abbau_plan.md renamed the switch after the surface it
  # was named for was gone. It gates whether a connected repository is INDEXED, which
  # is what it always did.
  describe 'PATCH /admin/organisations/:id/toggle_code_indexing' do
    it 'enables code indexing when it was off, with a matching flash' do
      log_in_admin
      patch toggle_code_indexing_admin_organisation_path(organisation)

      expect(organisation.reload.code_indexing_enabled).to be(true)
      expect(response).to redirect_to(admin_organisations_path)
      # Pins the flash AND the on/off state label, both otherwise behaviourally untested.
      expect(flash[:notice]).to eq(
        I18n.t('flash.admin.organisations.toggle_success', name: organisation.name,
                                                           state: I18n.t('admin.organisations.index.code_indexing_on'))
      )
    end

    it 'disables it again when it was on (a real toggle), with the off-state flash' do
      organisation.update!(code_indexing_enabled: true)
      log_in_admin
      patch toggle_code_indexing_admin_organisation_path(organisation)

      expect(organisation.reload.code_indexing_enabled).to be(false)
      expect(flash[:notice]).to include(I18n.t('admin.organisations.index.code_indexing_off'))
    end

    it 'requires a logged-in operator — anonymous cannot flip the flag' do
      patch toggle_code_indexing_admin_organisation_path(organisation)

      expect(response).to redirect_to(admin_log_in_path)
      expect(organisation.reload.code_indexing_enabled).to be(false) # untouched
    end

    it 'rejects a NON-admin beuser — operator-gated, not merely authenticated' do
      non_admin = create(:beuser, role: 'user') # factory defaults to 'admin'; override
      post admin_log_in_path, params: { email: non_admin.email, password: non_admin.password }
      expect(response).to redirect_to(admin_log_in_path) # login refused → no session set

      patch toggle_code_indexing_admin_organisation_path(organisation)
      expect(response).to redirect_to(admin_log_in_path)
      expect(organisation.reload.code_indexing_enabled).to be(false) # untouched
    end

    it 'returns 404 for a nonexistent organisation id' do
      log_in_admin
      patch toggle_code_indexing_admin_organisation_path('00000000-0000-0000-0000-000000000000')

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'PATCH /admin/organisations/:id/toggle_data_import' do
    it 'switches the CodebaseHQ import on when it was off, with a matching flash' do
      log_in_admin
      patch toggle_data_import_admin_organisation_path(organisation)

      expect(organisation.reload.data_import_enabled).to be(true)
      expect(response).to redirect_to(admin_organisations_path)
      expect(flash[:notice]).to eq(
        I18n.t('flash.admin.organisations.toggle_data_import_success', name: organisation.name,
                                                                       state: I18n.t('admin.organisations.index.data_import_on'))
      )
    end

    it 'switches it off again when it was on (a real toggle), with the off-state flash' do
      organisation.update!(data_import_enabled: true)
      log_in_admin
      patch toggle_data_import_admin_organisation_path(organisation)

      expect(organisation.reload.data_import_enabled).to be(false)
      expect(flash[:notice]).to include(I18n.t('admin.organisations.index.data_import_off'))
    end

    # The point of putting the switch in the OPERATOR area: an org admin has no
    # business turning a vendor-specific importer on for their own organisation.
    it 'requires a logged-in operator — anonymous cannot flip the flag' do
      patch toggle_data_import_admin_organisation_path(organisation)

      expect(response).to redirect_to(admin_log_in_path)
      expect(organisation.reload.data_import_enabled).to be(false) # untouched
    end

    it 'rejects a NON-admin beuser — operator-gated, not merely authenticated' do
      non_admin = create(:beuser, role: 'user')
      post admin_log_in_path, params: { email: non_admin.email, password: non_admin.password }

      patch toggle_data_import_admin_organisation_path(organisation)
      expect(response).to redirect_to(admin_log_in_path)
      expect(organisation.reload.data_import_enabled).to be(false) # untouched
    end

    # Two flags now share #toggle_flag!. This pins that flipping one leaves the other
    # alone — the failure mode a shared helper with a wrong attribute would produce.
    it 'leaves the project-chat flag untouched' do
      organisation.update!(code_indexing_enabled: true)
      log_in_admin
      patch toggle_data_import_admin_organisation_path(organisation)

      expect(organisation.reload.code_indexing_enabled).to be(true)
      expect(organisation.data_import_enabled).to be(true)
    end

    it 'returns 404 for a nonexistent organisation id' do
      log_in_admin
      patch toggle_data_import_admin_organisation_path('00000000-0000-0000-0000-000000000000')

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET /admin/organisations (the toggle column)' do
    it 'renders the state badge + toggle button targeting the toggle route' do
      organisation.update!(code_indexing_enabled: true)
      log_in_admin
      get admin_organisations_path

      expect(response.body).to include(I18n.t('admin.organisations.index.code_indexing_on'))     # badge reflects state
      expect(response.body).to include(I18n.t('admin.organisations.index.toggle_code_indexing')) # button label
      expect(response.body).to include(toggle_code_indexing_admin_organisation_path(organisation)) # targets route
    end

    # The route path is the only UNIQUE needle here: both flags render the same
    # "An"/"Umschalten" wording, so asserting on the label alone would pass while
    # the column pointed at the wrong switch.
    it 'renders a second switch for the data-import flag targeting its own route' do
      organisation # the row has to exist BEFORE the page is fetched
      log_in_admin
      get admin_organisations_path

      expect(response.body).to include(toggle_data_import_admin_organisation_path(organisation))
      expect(response.body).to include(I18n.t('admin.organisations.index.table.data_import'))
    end
  end

  # "Welche KI nutzt diese Org?" — the column that replaced domain/subdomain.
  describe 'GET /admin/organisations (the AI-routing column)' do
    it 'names the SYSTEM credential an org actually routes through' do
      create(:ai_credential, :active, provider: 'openai', name: 'System OpenAI',
                                      display_name: 'OpenAI (GPT)', default_model: 'gpt-5')
      organisation
      log_in_admin
      get admin_organisations_path

      expect(response.body).to include('OpenAI (GPT)')
      expect(response.body).to include('gpt-5')
      expect(response.body).to include(I18n.t('admin.organisations.ai_routing.source_system'))
    end

    # The defect this column exists for: a curated org brought no token, so the
    # old badge called it "System-Credentials" — while it routes through the
    # credential its PACKAGE names.
    it 'names the PACKAGE credential for a curated org instead of the system one' do
      create(:ai_credential, :active, provider: 'openai', name: 'System OpenAI', display_name: 'OpenAI (GPT)')
      package = create(:ai_package, :with_tiers)
      package.tiers.find_by(key: 'fast').chat_credential.update!(display_name: 'Mistral (EU)')
      organisation.update!(ai_package: package, ai_package_tier_key: 'fast')
      log_in_admin
      get admin_organisations_path

      expect(response.body).to include('Mistral (EU)')
      expect(response.body).to include(I18n.t('admin.organisations.ai_routing.source_package'))
      expect(response.body).to include(package.name)
      # The stats card splits the non-BYOK remainder by where it routes.
      expect(response.body).to include(I18n.t('admin.organisations.index.stats.routing_split',
                                              package: 1, system: 0))
    end

    it 'no longer renders the domain and subdomain columns' do
      organisation.update!(domain: 'kundendomain.example.com', subdomain: 'kundensubdomain')
      log_in_admin
      get admin_organisations_path

      expect(response.body).not_to include('kundendomain.example.com')
      expect(response.body).not_to include('kundensubdomain')
    end
  end

  describe 'GET /admin/organisations/:id (the AI-routing card)' do
    it 'states the chat lane AND the search lane' do
      create(:ai_credential, :active, provider: 'openai', name: 'System OpenAI',
                                      display_name: 'OpenAI (GPT)', default_model: 'gpt-5')
      log_in_admin
      get admin_organisation_path(organisation)

      expect(response.body).to include(I18n.t('admin.organisations.show.ai_routing_section'))
      expect(response.body).to include(I18n.t('admin.organisations.show.ai_routing_search'))
      expect(response.body).to include('OpenAI (GPT)') # chat label
      expect(response.body).to include('gpt-5')
    end
  end

  # S3 KI-Kontingent: per-org budget/buffer overrides + Nachweis-Historie.
  describe 'GET /admin/organisations/:id (quota detail)' do
    let(:organisation) { create(:organisation, ai_quota_credits_override: 10, ai_quota_buffer_override: 5) }
    let!(:credential) { create(:ai_credential, :active, provider: 'openai', included_in_quota: true) }

    it 'shows the consumption bar with real used/budget values' do
      AiUsage.create!(organisation: organisation, provider: 'openai', ai_credential: credential,
                      credits_used: 4, used_at: Time.current)
      log_in_admin
      get admin_organisation_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('shared.ai.quota.used_of', used: 4, budget: 10, percent: 40))
      expect(response.body).to include(I18n.t('admin.organisations.show.history_section'))
    end

    it 'requires a logged-in operator' do
      get admin_organisation_path(organisation)
      expect(response).to redirect_to(admin_log_in_path)
    end
  end

  describe 'PATCH /admin/organisations/:id (quota override)' do
    let(:organisation) { create(:organisation, ai_quota_credits_override: 10) }

    it 'updates the override and redirects with a flash' do
      log_in_admin
      patch admin_organisation_path(organisation), params: { organisation: { ai_quota_credits_override: 50 } }

      expect(organisation.reload.ai_quota_credits_override).to eq(50)
      expect(response).to redirect_to(admin_organisation_path(organisation))
      expect(flash[:notice]).to eq(I18n.t('flash.admin.organisations.quota_updated', name: organisation.name))
    end

    it 'enqueues a resume when the budget is RAISED (paused embeddings catch up)' do
      log_in_admin
      expect(AiQuotaResumeJob).to receive(:perform_later).with(organisation)
      patch admin_organisation_path(organisation), params: { organisation: { ai_quota_credits_override: 500 } }
    end

    # Review 2026-07-13 (codex): raising ONLY the buffer also lifts the hard limit and
    # un-gates the org, so it must trigger the resume too — the hook compares hard_limit.
    it 'enqueues a resume when only the BUFFER is raised (hard limit increases)' do
      log_in_admin
      expect(AiQuotaResumeJob).to receive(:perform_later).with(organisation)
      patch admin_organisation_path(organisation), params: { organisation: { ai_quota_buffer_override: 500 } }
    end

    it 'does NOT enqueue a resume when the budget is lowered' do
      log_in_admin
      expect(AiQuotaResumeJob).not_to receive(:perform_later)
      patch admin_organisation_path(organisation), params: { organisation: { ai_quota_credits_override: 2 } }
    end

    it 'clears the override (blank → back to the system default)' do
      log_in_admin
      patch admin_organisation_path(organisation), params: { organisation: { ai_quota_credits_override: '' } }
      expect(organisation.reload.ai_quota_credits_override).to be_nil
    end
  end

  # S3a (§13-2, operator level): the assistant flag is a SEPARATE per-org switch,
  # so an org can keep the project chat without getting the org-wide assistant.
  describe 'PATCH /admin/organisations/:id/toggle_assistant' do
    it 'enables the per-org assistant when it was off, with a matching flash' do
      log_in_admin
      patch toggle_assistant_admin_organisation_path(organisation)

      expect(organisation.reload.assistant_enabled).to be(true)
      expect(response).to redirect_to(admin_organisations_path)
      expect(flash[:notice]).to eq(
        I18n.t('flash.admin.organisations.toggle_assistant_success',
               name: organisation.name,
               state: I18n.t('admin.organisations.index.assistant_on'))
      )
    end

    it 'disables it again when it was on (a real toggle), with the off-state flash' do
      organisation.update!(assistant_enabled: true)
      log_in_admin
      patch toggle_assistant_admin_organisation_path(organisation)

      expect(organisation.reload.assistant_enabled).to be(false)
      expect(flash[:notice]).to include(I18n.t('admin.organisations.index.assistant_off'))
    end

    it 'requires a logged-in operator — anonymous cannot flip the flag' do
      patch toggle_assistant_admin_organisation_path(organisation)

      expect(response).to redirect_to(admin_log_in_path)
      expect(organisation.reload.assistant_enabled).to be(false) # untouched
    end

    it 'leaves code_indexing_enabled alone (separate gates)' do
      log_in_admin
      patch toggle_assistant_admin_organisation_path(organisation)

      expect(organisation.reload.code_indexing_enabled).to be(false)
    end
  end

  describe 'GET /admin/organisations (the assistant toggle column)' do
    it 'renders the state badge + toggle button targeting the assistant route' do
      organisation.update!(assistant_enabled: true)
      log_in_admin
      get admin_organisations_path

      expect(response.body).to include(I18n.t('admin.organisations.index.assistant_on'))
      # The route path is the only UNIQUE needle (same wording as the other flags).
      expect(response.body).to include(toggle_assistant_admin_organisation_path(organisation))
    end
  end
end
