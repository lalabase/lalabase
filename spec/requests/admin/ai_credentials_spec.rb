# frozen_string_literal: true

require 'rails_helper'

# Request spec for the admin AI-credentials form, focused on the openai_compatible
# provider + its endpoint URL (additional_config['uri_base']) wiring added for the
# embedding-provider abstraction.
RSpec.describe 'Admin::AiCredentials', type: :request do
  let(:admin_beuser) { create(:beuser) } # role 'admin'

  def log_in_admin
    post admin_log_in_path, params: { email: admin_beuser.email, password: admin_beuser.password }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  describe 'GET /admin/ai_credentials' do
    it 'renders purpose, billing and 30d-usage columns with a compact key fingerprint (no asterisk wall)' do
      credential = create(:admin_ai_credential,
                          name: 'Prod OpenAI',
                          access_token: "sk-proj-#{'x' * 150}9aB2",
                          provider: 'openai',
                          purpose: 'both',
                          included_in_quota: true,
                          input_cost_per_1m_cents: 10,
                          output_cost_per_1m_cents: 30,
                          embedding_cost_per_1m_cents: 2)
      organisation = create(:organisation)
      create(:admin_ai_usage, ai_credential: credential, organisation: organisation,
                              provider: 'openai', tokens_used: 60_328, cost_cents: 42, used_at: 5.days.ago)
      log_in_admin

      get admin_ai_credentials_path

      expect(response).to have_http_status(:ok)
      # New information-dense columns replace the useless full-width masked key
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.index.th_purpose'))
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.index.th_billing'))
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.index.th_usage_30d'))
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.index.billing_metered'))
      # Per-1M prices for the metered credential are surfaced
      expect(response.body).to include('10/30 ct/1M')
      # Compact fingerprint instead of the old scroll-breaking wall of asterisks
      expect(response.body).to include(credential.key_fingerprint)
      expect(response.body).not_to match(/\*{20,}/)
      # 30d consumption is rendered per credential
      expect(response.body).to include(ActiveSupport::NumberHelper.number_to_delimited(60_328))
      # A Details (GET) link to the show page — where the availability matrix
      # lives — is offered per row, so the detail page is reachable from the list.
      expect(response.body).to include('bi-eye')
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.index.tooltip_details'))
      expect(response.body).not_to include('translation missing')
    end
  end

  describe 'GET /admin/ai_credentials/new' do
    it 'offers the openai_compatible provider and an endpoint-URL field' do
      log_in_admin

      get new_admin_ai_credential_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('openai_compatible')
      expect(response.body).to include('ai_credential[additional_config][uri_base]')
      expect(response.body).not_to include('translation missing')
    end

    # S2 EU presets: the new form carries the preset select (one option per
    # EU_CHAT_PRESETS entry) plus the Stimulus controller that copies the
    # selected preset into the form fields.
    it 'renders the EU preset select with one option per preset' do
      log_in_admin

      get new_admin_ai_credential_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('eu_chat_preset')
      expect(response.body).to include('admin-ai-credential-preset')
      AiCredential::EU_CHAT_PRESETS.each do |key, preset|
        expect(response.body).to include(%(value="#{key}")),
                                 "Expected an option for preset '#{key}'"
        expect(response.body).to include(preset[:display_name])
      end
      # Field ids the Stimulus controller fills — pins the JS<->markup seam.
      %w[provider api_base default_model display_name region purpose].each do |field|
        expect(response.body).to include(%(id="ai_credential_#{field}")),
                                 "Expected form field id ai_credential_#{field}"
      end
      expect(response.body).not_to include('translation missing')
    end
  end

  describe 'POST /admin/ai_credentials' do
    it 'stores the endpoint URL in additional_config for an openai_compatible credential' do
      log_in_admin

      post admin_ai_credentials_path, params: {
        ai_credential: {
          name: 'Sovereign Embeddings',
          provider: 'openai_compatible',
          access_token: 'sk-local',
          default_model: 'bge-m3-1536',
          additional_config: { uri_base: 'https://llm.internal/v1' }
        }
      }

      credential = AiCredential.find_by(name: 'Sovereign Embeddings')
      expect(credential).to be_present
      expect(credential.provider).to eq('openai_compatible')
      expect(credential.additional_config['uri_base']).to eq('https://llm.internal/v1')
    end
  end

  describe 'GET /admin/ai_credentials/:id/edit' do
    # The subtitle uses a *_html translation: t() escapes the interpolated name itself.
    # Pinned so the view can do without a trailing .html_safe (a Brakeman XSS warning).
    it 'escapes the credential name in the subtitle' do
      credential = create(:ai_credential, name: '<script>alert(1)</script>')
      log_in_admin

      get edit_admin_ai_credential_path(credential)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<strong>&lt;script&gt;alert(1)&lt;/script&gt;</strong>')
      expect(response.body).not_to include('<script>alert(1)</script>')
    end

    it 'renders the endpoint-URL field with its current value (no missing translations)' do
      credential = create(:ai_credential, provider: 'openai_compatible',
                                          default_model: 'bge-m3-1536',
                                          additional_config: { 'uri_base' => 'https://existing/v1' })
      log_in_admin

      get edit_admin_ai_credential_path(credential)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('ai_credential[additional_config][uri_base]')
      expect(response.body).to include('https://existing/v1')
      expect(response.body).not_to include('translation missing')
    end

    it 'does not render the EU preset select (prefill is a new-form aid only)' do
      credential = create(:ai_credential, provider: 'openai_compatible',
                                          default_model: 'bge-m3-1536')
      log_in_admin

      get edit_admin_ai_credential_path(credential)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('eu_chat_preset')
    end
  end

  describe 'PATCH /admin/ai_credentials/:id' do
    it 'updates the endpoint URL' do
      credential = create(:ai_credential, provider: 'openai_compatible',
                                          default_model: 'bge-m3-1536',
                                          additional_config: { 'uri_base' => 'https://old/v1' })
      log_in_admin

      patch admin_ai_credential_path(credential), params: {
        ai_credential: { additional_config: { uri_base: 'https://new/v1' } }
      }

      expect(credential.reload.additional_config['uri_base']).to eq('https://new/v1')
    end
  end

  # E12 (doc/ki_pakete_plan.md §3.3): the second jurisdiction axis. The rejected
  # alternative was deriving the firm seat from the provider NAME — impossible
  # for the three EU presets that all run as openai_compatible. So it is a stored
  # field, and a field only exists if the form renders it AND the permit list
  # takes it: the two halves fail independently and both fail silently.
  describe 'company_domicile (the provider firm seat)' do
    it 'renders the select on the edit form' do
      credential = create(:ai_credential, provider: 'openai_compatible', company_domicile: 'eu')
      log_in_admin

      get edit_admin_ai_credential_path(credential)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('ai_credential[company_domicile]')
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.seam.label_company_domicile'))
      expect(response.body).not_to include('translation missing')
    end

    it 'persists the submitted domicile' do
      credential = create(:ai_credential, provider: 'openai_compatible', company_domicile: nil)
      log_in_admin

      patch admin_ai_credential_path(credential), params: {
        ai_credential: { company_domicile: 'non_eu' }
      }

      expect(credential.reload.company_domicile).to eq('non_eu')
    end
  end

  # REGRESSION (KI-Pakete P0): this is the app's ONLY destroy path for AI
  # credentials, and it loads Admin::AiCredential — the class that did not carry
  # the last-active guard. Deleting a provider's only active credential therefore
  # succeeded silently and left runtime traffic without a credential.
  describe 'DELETE /admin/ai_credentials/:id' do
    it 'refuses to delete the last active credential of a provider and names the reason' do
      credential = create(:admin_ai_credential, :active, provider: 'openai')
      log_in_admin

      delete admin_ai_credential_path(credential)

      expect(response).to redirect_to(admin_ai_credentials_path)
      expect(flash[:alert]).to eq(
        I18n.t('flash.shared.delete_error',
               error: I18n.t('activerecord.errors.models.ai_credential.cannot_delete_last_active', provider: 'openai'))
      )
      # Not the bare RecordNotDestroyed text — that says nothing an admin can act on.
      expect(flash[:alert]).not_to include('Failed to destroy')
      expect(Admin::AiCredential.find_by(id: credential.id)).to be_present
    end

    it 'deletes an inactive credential' do
      credential = create(:admin_ai_credential, active: false, region: 'eu')
      log_in_admin

      delete admin_ai_credential_path(credential)

      expect(response).to redirect_to(admin_ai_credentials_path)
      expect(flash[:notice]).to eq(I18n.t('flash.admin.ai_credentials.deleted'))
      expect(Admin::AiCredential.find_by(id: credential.id)).to be_nil
    end

    # KI-Pakete P1 (§7b.2): the show page disables the button, but the route
    # stays reachable (bookmark, second tab, a package pinned after the page was
    # rendered). The callback is the line that actually holds — and it must name
    # the packages, because "Failed to destroy" tells an operator nothing.
    it 'refuses to delete a credential referenced by a package and names the package' do
      credential = create(:admin_ai_credential, active: false, region: 'eu')
      package = create(:ai_package, embedding_credential_id: credential.id)
      log_in_admin

      delete admin_ai_credential_path(credential)

      expect(response).to redirect_to(admin_ai_credentials_path)
      expect(flash[:alert]).to eq(
        I18n.t('flash.shared.delete_error',
               error: I18n.t('activerecord.errors.models.ai_credential.cannot_delete_referenced_by_package',
                             packages: package.name))
      )
      expect(flash[:alert]).to include(package.name)
      expect(Admin::AiCredential.find_by(id: credential.id)).to be_present
    end
  end

  # The credential list answers "which of these three openai_compatible rows is
  # which?" by what uses them — the packages column (§7b.2).
  describe 'package references in the credential masks' do
    it 'renders a linked package badge per reference on the index, with the role' do
      embedding_credential = create(:admin_ai_credential, active: false, region: 'eu', name: 'Mistral EU')
      chat_credential = create(:admin_ai_credential, active: false, region: 'eu', name: 'Vertex Frankfurt')
      package = create(:ai_package, embedding_credential_id: embedding_credential.id)
      create(:ai_package_tier, ai_package: package, chat_credential_id: chat_credential.id,
                               key: 'thorough', label: AiPackageTier::DEFAULT_LABELS.fetch('thorough'))
      log_in_admin

      get admin_ai_credentials_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.index.th_packages'))
      # Embedding slot and chat tier are told apart by the badge's second half.
      expect(response.body).to include(
        I18n.t('views.admin.ai_credentials.shared.package_badge', package: package.name,
                                                                  role: I18n.t('views.admin.ai_credentials.shared.package_role_embedding'))
      )
      expect(response.body).to include(
        I18n.t('views.admin.ai_credentials.shared.package_badge', package: package.name,
                                                                  role: AiPackageTier::DEFAULT_LABELS.fetch('thorough'))
      )
      expect(response.body).to include(admin_ai_package_path(package))
      expect(response.body).not_to include('translation missing')
    end

    it 'shows the effective name next to the routing key (three EU presets share one provider)' do
      create(:admin_ai_credential, name: 'eu-compat-2', display_name: 'Mistral (EU)',
                                   provider: 'openai_compatible', default_model: 'bge-m3-1536')
      log_in_admin

      get admin_ai_credentials_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Mistral (EU)')
    end

    it 'marks unreferenced credentials with a quiet dash rather than an empty cell' do
      create(:admin_ai_credential, active: false, region: 'eu')
      log_in_admin

      get admin_ai_credentials_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.index.th_packages'))
      expect(response.body).not_to include('translation missing')
    end

    # Guards the grouped lookup: a per-row call would scale with the list.
    it 'resolves the whole page in two package queries, not one per credential' do
      # Paused for the SETUP only — three package saves each validate their own
      # credential, which is per-record work and not the N+1 under test. The
      # request below stays scanned, so Prosopite still guards the render.
      Prosopite.pause do
        3.times do
          credential = create(:admin_ai_credential, active: false, region: 'eu')
          create(:ai_package, embedding_credential_id: credential.id)
        end
      end
      log_in_admin

      package_queries = 0
      counter = lambda do |_name, _started, _finished, _id, payload|
        package_queries += 1 if payload[:sql]&.match?(/"ai_packages"|"ai_package_tiers"/)
      end

      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        get admin_ai_credentials_path
      end

      expect(response).to have_http_status(:ok)
      expect(package_queries).to eq(2)
    end

    it 'lists the referencing packages on the detail page and disables the delete button' do
      credential = create(:admin_ai_credential, active: false, region: 'eu')
      package = create(:ai_package, embedding_credential_id: credential.id)
      log_in_admin

      get admin_ai_credential_path(credential)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.show.section_packages'))
      expect(response.body).to include(
        I18n.t('views.admin.ai_credentials.shared.package_badge', package: package.name,
                                                                  role: I18n.t('views.admin.ai_credentials.shared.package_role_embedding'))
      )
      expect(response.body).to include(
        I18n.t('views.admin.ai_credentials.show.btn_delete_blocked_title', packages: package.name)
      )
      # The live delete control is the ONLY turbo_method: :delete on this page —
      # its absence is what "disabled" means here.
      expect(response.body).not_to include('data-turbo-method="delete"')
      expect(response.body).not_to include('translation missing')
    end

    it 'keeps the delete button live when no package references the credential' do
      credential = create(:admin_ai_credential, active: false, region: 'eu')
      log_in_admin

      get admin_ai_credential_path(credential)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('views.admin.ai_credentials.show.packages_none'))
      expect(response.body).to include('data-turbo-method="delete"')
      expect(response.body).not_to include(
        I18n.t('views.admin.ai_credentials.show.btn_delete_blocked_title', packages: '')
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Google Vertex AI (Slice 3): SA-JSON textarea + project_id/location fields,
  # and the masked-token write-back guard for the JSON secret (plan §9 risk 10).
  # ---------------------------------------------------------------------------
  describe 'google credential form (Vertex AI)' do
    it 'renders the SA-JSON textarea and the project_id/location fields on the new form' do
      log_in_admin

      get new_admin_ai_credential_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('ai_credential_access_token_sa_json')
      expect(response.body).to include('ai_credential[additional_config][project_id]')
      expect(response.body).to include('ai_credential[additional_config][location]')
      expect(response.body).to include('admin-ai-credential-token-field')
      expect(response.body).not_to include('translation missing')
    end

    it 'creates a google credential with SA JSON and regional routing config' do
      log_in_admin

      sa_json = { type: 'service_account', project_id: 'lala-eu',
                  private_key: 'PEM', client_email: 'svc@lala-eu.iam.gserviceaccount.com' }.to_json
      post admin_ai_credentials_path, params: {
        ai_credential: {
          name: 'Vertex EU',
          provider: 'google',
          access_token: sa_json,
          default_model: 'gemini-2.0-flash',
          additional_config: { project_id: 'lala-eu', location: 'europe-west3' }
        }
      }

      credential = AiCredential.find_by(name: 'Vertex EU')
      expect(credential).to be_present
      expect(credential.access_token).to eq(sa_json)
      expect(credential.additional_config).to include('project_id' => 'lala-eu', 'location' => 'europe-west3')
    end

    it 'rejects a google credential whose token is not a service-account JSON' do
      log_in_admin

      post admin_ai_credentials_path, params: {
        ai_credential: {
          name: 'Vertex broken', provider: 'google',
          access_token: 'AIzaSyNotAllowed', default_model: 'gemini-2.0-flash'
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(AiCredential.find_by(name: 'Vertex broken')).to be_nil
    end

    it 'keeps the stored SA JSON when the masked value round-trips on update (write-back guard)' do
      credential = create(:ai_credential, :google)
      original_json = credential.access_token
      log_in_admin

      patch admin_ai_credential_path(credential), params: {
        ai_credential: { access_token: credential.masked_token, description: 'rotated nothing' }
      }

      expect(credential.reload.access_token).to eq(original_json)
      expect(credential.description).to eq('rotated nothing')
    end

    it 'replaces the SA JSON when a fresh (unmasked) JSON is submitted' do
      credential = create(:ai_credential, :google)
      log_in_admin

      new_json = { type: 'service_account', project_id: 'lala-eu',
                   private_key: 'NEWPEM', client_email: 'rotated@lala-eu.iam.gserviceaccount.com' }.to_json
      patch admin_ai_credential_path(credential), params: {
        ai_credential: { access_token: new_json }
      }

      expect(credential.reload.access_token).to eq(new_json)
    end

    it 'renders the SA-JSON textarea (not the API-key field) as the enabled secret input on edit' do
      credential = create(:ai_credential, :google)
      log_in_admin

      get edit_admin_ai_credential_path(credential)

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      sa_textarea = doc.at_css('#ai_credential_access_token_sa_json')
      api_key_input = doc.at_css('#ai_credential_access_token')
      # Exactly ONE of the two access_token inputs may be enabled — otherwise
      # the browser would submit two values for the same attribute.
      expect(sa_textarea).to be_present
      expect(sa_textarea['disabled']).to be_nil
      expect(api_key_input['disabled']).to be_present
      expect(response.body).not_to include('translation missing')
    end
  end
end

# ---------------------------------------------------------------------------
# Regressions from the pre-landing review of PR #399.
# ---------------------------------------------------------------------------
RSpec.describe 'Admin::AiCredentials review regressions', type: :request do
  let(:admin_beuser) { create(:beuser) }

  def log_in_admin
    post admin_log_in_path, params: { email: admin_beuser.email, password: admin_beuser.password }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  # The delete guard covered `destroy` only. Disabling has the same runtime
  # effect — the package's own validations reject a disabled credential — so the
  # operator could take a published package's credential out from under it with
  # one click, and the package was then unsaveable from its own form.
  describe 'PATCH toggle_enabled on a credential a package references' do
    it 'refuses, reports the package, and leaves the credential enabled' do
      credential = create(:admin_ai_credential, active: false, region: 'eu')
      package = create(:ai_package, :with_tiers, embedding_credential_id: credential.id, active: true)
      log_in_admin

      patch toggle_enabled_admin_ai_credential_path(credential)

      expect(credential.reload.enabled).to be(true)
      expect(flash[:alert]).to include(package.name)
    end

    it 'still allows disabling an unreferenced credential' do
      credential = create(:admin_ai_credential, active: false, region: 'eu')
      log_in_admin

      patch toggle_enabled_admin_ai_credential_path(credential)

      expect(credential.reload.enabled).to be(false)
    end
  end

  # The delete control is a link_to + data-turbo-method, so Turbo issues a real
  # DELETE fetch. A 302 makes the browser RE-ISSUE the DELETE against the
  # redirect target, and DELETE /admin/ai_credentials has no route — the
  # operator saw a routing error after a successful delete. 303 downgrades to GET.
  describe 'DELETE responds with See Other so Turbo follows it as a GET' do
    it 'answers 303 on success' do
      credential = create(:admin_ai_credential, active: false, region: 'eu')
      log_in_admin

      delete admin_ai_credential_path(credential)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(admin_ai_credentials_path)
    end

    it 'answers 303 when the package guard refuses' do
      credential = create(:admin_ai_credential, active: false, region: 'eu')
      create(:ai_package, embedding_credential_id: credential.id)
      log_in_admin

      delete admin_ai_credential_path(credential)

      expect(response).to have_http_status(:see_other)
      expect(credential.reload).to be_present
    end
  end

  # The reason a delete is blocked used to live only in a title tooltip on a
  # non-focusable span — unreachable by keyboard, screen reader and touch.
  describe 'the blocked delete button states its reason in the DOM' do
    it 'renders the package names as visible text, not only as a tooltip' do
      credential = create(:admin_ai_credential, active: false, region: 'eu')
      package = create(:ai_package, embedding_credential_id: credential.id)
      log_in_admin

      get admin_ai_credential_path(credential)

      doc = Nokogiri::HTML(response.body)
      reason = doc.at_css('#delete-blocked-reason')
      expect(reason).to be_present
      expect(reason.text).to include(package.name)
      expect(doc.at_css('[aria-describedby="delete-blocked-reason"]')['aria-disabled']).to eq('true')
    end
  end
end
