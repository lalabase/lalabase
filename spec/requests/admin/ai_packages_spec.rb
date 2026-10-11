# frozen_string_literal: true

require 'rails_helper'

# Request spec (real Beuser session + routes) for the operator CRUD of the
# curated AI offerings (KI-Pakete, doc/ki_pakete_plan.md §7b.1). Mirrors
# admin/prompt_personas_spec: a GLOBAL, Beuser-gated resource — no tenant, no
# Pundit, auth purely through Admin::ApplicationController.
RSpec.describe 'Admin::AiPackages', type: :request do
  let(:admin_beuser) { create(:beuser) } # factory: role 'admin', active

  def log_in_admin
    post admin_log_in_path, params: { email: admin_beuser.email, password: admin_beuser.password }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  # The shape the selects offer: enabled, purpose 'both' (chat AND embedding
  # capable), priced. Deliberately all on ONE provider here — the point of
  # Falle 2 is that the form never couples the two credential choices.
  # region: 'eu' throughout — every package here claims jurisdiction 'eu_native',
  # and that claim fails closed against a credential whose residency nobody
  # stated (AiPackage#jurisdiction_must_not_contradict_credentials).
  let(:embedding_credential) { create(:ai_credential, name: 'Mistral EU', region: 'eu') }
  let(:fast_credential) { create(:ai_credential, name: 'Fast chat', region: 'eu') }
  let(:thorough_credential) { create(:ai_credential, name: 'Thorough chat', region: 'eu') }

  # STATIC child indexes 0/1, exactly as the fixed-slot form renders them
  # (§7b.1 option C). permit drops non-integer nested keys silently — this is
  # the submission shape that constructively cannot hit that trap.
  def package_params(overrides = {})
    {
      ai_package: {
        name: 'Europäisch',
        description: 'Verarbeitung in Frankreich durch Mistral AI, ein französisches Unternehmen.',
        jurisdiction: 'eu_native',
        processing_region: 'Frankreich',
        provider_note: 'Keine Trainingsnutzung; Aufbewahrung 30 Tage.',
        embedding_credential_id: embedding_credential.id,
        embedding_model: 'mistral-embed',
        embedding_dims: 1024,
        active: '1',
        position: 1,
        tiers_attributes: {
          '0' => { key: 'fast', label: AiPackageTier::DEFAULT_LABELS.fetch('fast'),
                   chat_credential_id: fast_credential.id, chat_model: 'mistral-small', position: 0 },
          '1' => { key: 'thorough', label: AiPackageTier::DEFAULT_LABELS.fetch('thorough'),
                   chat_credential_id: thorough_credential.id, chat_model: '', position: 1 }
        }
      }.merge(overrides)
    }
  end

  describe 'authentication (operator-gated, not merely authenticated)' do
    it 'redirects an anonymous visitor to the admin login' do
      get admin_ai_packages_path
      expect(response).to redirect_to(admin_log_in_path)
    end

    it 'rejects a NON-admin beuser (login refused → no session)' do
      non_admin = create(:beuser, role: 'user')
      post admin_log_in_path, params: { email: non_admin.email, password: non_admin.password }

      get admin_ai_packages_path

      expect(response).to redirect_to(admin_log_in_path)
    end
  end

  describe 'GET /admin/ai_packages' do
    it 'lists packages with the FULL jurisdiction wording and the tier count' do
      create(:ai_package, :with_tiers, name: 'Europäisch', jurisdiction: 'eu_native')
      log_in_admin

      get admin_ai_packages_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Europäisch')
      # Never a shorthand: this claim ends up in the AVV (§9 Falle 6).
      expect(response.body).to include(I18n.t('views.admin.ai_packages.jurisdictions.eu_native'))
      expect(response.body).to include(I18n.t('views.admin.ai_packages.index.tier_count', count: 2))
      expect(response.body).not_to include('translation missing')
    end

    it 'renders the empty state when no package exists yet' do
      log_in_admin

      get admin_ai_packages_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('views.admin.ai_packages.index.empty_title'))
    end
  end

  describe 'GET /admin/ai_packages/new' do
    it 'prebuilds BOTH fixed tier slots and offers no kind field' do
      embedding_credential
      fast_credential
      log_in_admin

      get new_admin_ai_package_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      # key/label are rendered READ-ONLY and never posted — the controller
      # re-derives both from the slot index, so a tampered hidden field cannot
      # reach the DB index any more.
      expect(doc.at_css('input[name="ai_package[tiers_attributes][0][key]"]')).to be_nil
      expect(doc.at_css('input[name="ai_package[tiers_attributes][0][label]"]')).to be_nil
      expect(doc.text).to include(AiPackageTier::DEFAULT_LABELS.fetch('fast'))
      expect(doc.text).to include(AiPackageTier::DEFAULT_LABELS.fetch('thorough'))
      expect(doc.at_css('select[name="ai_package[tiers_attributes][0][chat_credential_id]"]')).to be_present
      expect(doc.at_css('select[name="ai_package[embedding_credential_id]"]')).to be_present
      # kind is not a form field — the controller forces 'curated' (§7b.1).
      expect(doc.at_css('[name="ai_package[kind]"]')).to be_nil
      expect(response.body).not_to include('translation missing')
    end
  end

  describe 'GET /admin/ai_packages/:id/edit' do
    it 'renders the form for an existing package' do
      package = create(:ai_package, :with_tiers)
      log_in_admin

      get edit_admin_ai_package_path(package)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(package.embedding_model)
      expect(response.body).not_to include('translation missing')
    end
  end

  describe 'GET /admin/ai_packages/:id' do
    it 'gathers the customer-facing copy in one place' do
      package = create(:ai_package, :with_tiers, name: 'Europäisch',
                                                 provider_note: 'Kein Training auf Kundendaten.')
      log_in_admin

      get admin_ai_package_path(package)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Kein Training auf Kundendaten.')
      expect(response.body).to include(I18n.t('views.admin.ai_packages.jurisdictions.eu_native'))
      expect(response.body).to include(package.embedding_model)
      # No google credential referenced → the whole Vertex section stays off.
      expect(response.body).not_to include(I18n.t('views.admin.ai_packages.show.section_vertex'))
      expect(response.body).not_to include('translation missing')
    end

    it 'reports a google reference as UNVERIFIED (never green) while the probe cache is cold' do
      google = create(:ai_credential, :google)
      package = create(:ai_package, :with_tiers)
      # The tier's own save-time vertex validation probes; stub it away so the
      # strict expectation below measures ONLY what the GET does.
      allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:call).and_return(nil)
      package.tiers.find_by(key: 'fast').update!(chat_credential: google, chat_model: 'gemini-2.5-flash')
      log_in_admin

      # A GET only ever READS the probe cache — it must not fan out probes.
      expect(Lalabase::Llm::VertexAvailabilityProbe).not_to receive(:call)

      get admin_ai_package_path(package)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('views.admin.ai_packages.show.section_vertex'))
      expect(response.body).to include(I18n.t('views.admin.ai_packages.show.vertex_unknown'))
      expect(response.body).not_to include(I18n.t('views.admin.ai_packages.show.vertex_available'))
    end
  end

  describe 'POST /admin/ai_packages' do
    it 'creates the package plus BOTH tiers from the static nested indexes' do
      log_in_admin

      expect { post admin_ai_packages_path, params: package_params }
        .to change(AiPackage, :count).by(1)
        .and change(AiPackageTier, :count).by(2)

      package = AiPackage.find_by(name: 'Europäisch')
      expect(package.tiers.pluck(:key)).to match_array(AiPackageTier::KEYS)
      expect(package.tiers.find_by(key: 'fast').chat_credential).to eq(fast_credential)
      expect(package.tiers.find_by(key: 'thorough').chat_credential).to eq(thorough_credential)
      expect(package.embedding_credential).to eq(embedding_credential)
      expect(response).to redirect_to(admin_ai_packages_path)
    end

    it 'forces kind curated even when custom is injected into the params' do
      log_in_admin

      post admin_ai_packages_path, params: package_params(kind: 'custom')

      expect(AiPackage.find_by(name: 'Europäisch').kind).to eq('curated')
    end

    it 're-renders the form with the error box when the package is invalid' do
      log_in_admin

      post admin_ai_packages_path, params: package_params(name: '')

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).not_to include('translation missing')
    end

    it 'surfaces an ASSOCIATION-level error in the box' do
      # The model reports this on :embedding_credential, NOT on
      # :embedding_credential_id. The box renders errors.full_messages, so it
      # shows up either way — a field-level lookup on the _id would silently
      # swallow it, which is exactly what this guards against.
      chat_only = create(:ai_credential, name: 'Chat only', purpose: 'chat')
      log_in_admin

      post admin_ai_packages_path, params: package_params(embedding_credential_id: chat_only.id)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(AiPackage.human_attribute_name(:embedding_credential))
      expect(response.body).to include(
        I18n.t('activerecord.errors.models.ai_package.attributes.embedding_credential.wrong_purpose')
      )
      expect(response.body).not_to include('translation missing')
    end
  end

  describe 'PATCH /admin/ai_packages/:id' do
    it 'updates a field and publishes the package' do
      package = create(:ai_package, :with_tiers, name: 'Alt', active: false)
      log_in_admin

      patch admin_ai_package_path(package), params: { ai_package: { name: 'Neu', active: '1' } }

      expect(response).to redirect_to(admin_ai_packages_path)
      expect(package.reload.name).to eq('Neu')
      expect(package.active?).to be(true)
    end
  end

  describe 'DELETE /admin/ai_packages/:id' do
    it 'deletes the package and cascades its tiers' do
      package = create(:ai_package, :with_tiers)
      log_in_admin

      expect { delete admin_ai_package_path(package) }
        .to change(AiPackage, :count).by(-1)
        .and change(AiPackageTier, :count).by(-2)

      expect(response).to redirect_to(admin_ai_packages_path)
    end
  end

  describe 'POST /admin/ai_packages/:id/vertex_check' do
    it 'redirects back without probing when the package references no google credential' do
      package = create(:ai_package, :with_tiers)
      log_in_admin

      expect(Lalabase::Llm::VertexAvailabilityProbe).not_to receive(:call)

      post vertex_check_admin_ai_package_path(package)

      expect(response).to redirect_to(admin_ai_package_path(package))
      expect(flash[:alert]).to eq(I18n.t('flash.admin.ai_packages.vertex_check_unsupported'))
    end

    it 'probes FRESH (force_refresh) for every referenced google credential' do
      google = create(:ai_credential, :google)
      package = create(:ai_package, :with_tiers)
      allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:call).and_return(nil)
      package.tiers.find_by(key: 'thorough').update!(chat_credential: google)
      log_in_admin

      # force_refresh is the whole point of the button: the cache is what the
      # GET reads, this action is what fills it.
      expect(Lalabase::Llm::VertexAvailabilityProbe)
        .to receive(:call).with(credential_id: google.id, force_refresh: true).once

      post vertex_check_admin_ai_package_path(package)

      expect(response).to redirect_to(admin_ai_package_path(package))
      expect(flash[:notice]).to eq(I18n.t('flash.admin.ai_packages.vertex_checked'))
    end
  end
end

# ---------------------------------------------------------------------------
# Regressions from the pre-landing review of PR #399.
# ---------------------------------------------------------------------------
RSpec.describe 'Admin::AiPackages review regressions', type: :request do
  let(:admin_beuser) { create(:beuser) }

  def log_in_admin
    post admin_log_in_path, params: { email: admin_beuser.email, password: admin_beuser.password }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  let(:credential) { create(:ai_credential, name: 'Mistral EU', region: 'eu') }

  def package_params(overrides = {})
    {
      ai_package: {
        name: "Paket #{SecureRandom.hex(3)}",
        description: 'Ein Satz Klartext.',
        jurisdiction: 'eu_native',
        processing_region: 'Frankreich',
        provider_note: 'Keine Trainingsnutzung.',
        embedding_credential_id: credential.id,
        embedding_model: 'mistral-embed',
        embedding_dims: 1024,
        position: 1,
        tiers_attributes: {
          '0' => { chat_credential_id: credential.id, chat_model: 'mistral-small' },
          '1' => { chat_credential_id: credential.id, chat_model: '' }
        }
      }.merge(overrides)
    }
  end

  # The operator gate was only proven for GET index. These are the actions that
  # mutate the published catalogue and spend network I/O.
  describe 'the Beuser gate covers the WRITE actions, not just index' do
    it 'refuses an anonymous POST without creating anything' do
      expect { post admin_ai_packages_path, params: package_params }.not_to change(AiPackage, :count)
      expect(response).to redirect_to(admin_log_in_path)
    end

    it 'refuses an anonymous DELETE without destroying anything' do
      package = create(:ai_package, :with_tiers)

      expect { delete admin_ai_package_path(package) }.not_to change(AiPackage, :count)
      expect(response).to redirect_to(admin_log_in_path)
    end

    it 'refuses an anonymous vertex_check without probing' do
      package = create(:ai_package, :with_tiers)
      expect(Lalabase::Llm::VertexAvailabilityProbe).not_to receive(:call)

      post vertex_check_admin_ai_package_path(package)

      expect(response).to redirect_to(admin_log_in_path)
    end
  end

  # `key` and `label` used to be permitted hidden fields, so a crafted POST with
  # two identical keys passed model validation and hit the unique index —
  # ActiveRecord::RecordNotUnique, an unhandled 500. The controller now derives
  # both from the slot index, so the tampered values are simply ignored.
  describe 'tampered tier identity cannot crash the create' do
    it 'ignores an injected duplicate key and still builds the real ladder' do
      log_in_admin
      params = package_params
      params[:ai_package][:tiers_attributes]['0'][:key] = 'thorough'
      params[:ai_package][:tiers_attributes]['1'][:key] = 'thorough'

      expect { post admin_ai_packages_path, params: params }.to change(AiPackage, :count).by(1)

      expect(AiPackage.order(:created_at).last.tiers.map(&:key)).to match_array(AiPackageTier::KEYS)
    end

    it 'ignores an injected label and keeps the product wording' do
      log_in_admin
      params = package_params
      params[:ai_package][:tiers_attributes]['0'][:label] = '<gekapert>'

      post admin_ai_packages_path, params: params

      labels = AiPackage.order(:created_at).last.tiers.map(&:label)
      expect(labels).to match_array(AiPackageTier::DEFAULT_LABELS.values)
    end
  end

  # A cleared number_field submits "" — cast to nil and written explicitly, so
  # the NOT NULL default never applied and the INSERT 500'd, eating the form.
  describe 'a cleared position does not 500' do
    it 'creates the package with position 0' do
      log_in_admin

      expect { post admin_ai_packages_path, params: package_params(position: '') }
        .to change(AiPackage, :count).by(1)

      expect(AiPackage.order(:created_at).last.position).to eq(0)
    end
  end

  # vertex_state's green and red branches were never exercised: the only show
  # spec ran against a cold cache and asserted the yellow badge. Swapping
  # :available and :unavailable used to break nothing.
  describe 'the Vertex traffic light on the show page' do
    def google_package
      google = create(:ai_credential, :google, region: nil)
      create(:ai_package, embedding_credential: google, jurisdiction: 'eu_region_foreign_provider',
                          embedding_model: 'gemini-embedding-001', embedding_dims: 3072)
    end

    def matrix(status_code:, model: 'gemini-embedding-001', region: 'europe-west3')
      { checked_at: Time.current, project_id: 'lala-eu', regions: [region], models: [model],
        results: [{ region: region, model: model, status_code: status_code,
                    available: status_code == 200, info_only: false }] }
    end

    before { allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:cached).and_return(nil) }

    it 'renders GREEN when the cached cell says the model is available' do
      package = google_package
      allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:cached_for).and_return(matrix(status_code: 200))
      log_in_admin

      get admin_ai_package_path(package)

      expect(response.body).to include(I18n.t('views.admin.ai_packages.show.vertex_available'))
      expect(response.body).not_to include(I18n.t('views.admin.ai_packages.show.vertex_unavailable'))
    end

    it 'renders RED on a clear 404 — the finding that predicts silent breakage' do
      package = google_package
      allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:cached_for).and_return(matrix(status_code: 404))
      log_in_admin

      get admin_ai_package_path(package)

      expect(response.body).to include(I18n.t('views.admin.ai_packages.show.vertex_unavailable'))
      # NOT a plain negative on vertex_available: in DE it reads "verfügbar",
      # which is a substring of "nicht verfügbar". The red badge's own icon is
      # the unambiguous discriminator.
      expect(response.body).to include('bi-x-circle')
      expect(response.body).not_to include(I18n.t('views.admin.ai_packages.show.vertex_unknown'))
    end

    it 'falls back to YELLOW on any other status — never a green claim' do
      package = google_package
      allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:cached_for).and_return(matrix(status_code: 403))
      log_in_admin

      get admin_ai_package_path(package)

      expect(response.body).to include(I18n.t('views.admin.ai_packages.show.vertex_unknown'))
      expect(response.body).not_to include(I18n.t('views.admin.ai_packages.show.vertex_available'))
    end
  end

  # The failure branch of the only network-triggering action — the likeliest
  # path in production, since the button exists because probes fail.
  describe 'a failing vertex_check reports instead of 500ing' do
    it 'redirects with the error in the flash' do
      allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:cached).and_return(nil)
      google = create(:ai_credential, :google, region: nil)
      package = create(:ai_package, embedding_credential: google, jurisdiction: 'eu_region_foreign_provider',
                                    embedding_model: 'gemini-embedding-001', embedding_dims: 3072)
      log_in_admin
      allow(Lalabase::Llm::VertexAvailabilityProbe).to receive(:call)
        .and_raise(Lalabase::Llm::VertexAvailabilityProbe::ProbeError, 'no service account')

      post vertex_check_admin_ai_package_path(package)

      expect(response).to redirect_to(admin_ai_package_path(package))
      expect(flash[:alert]).to include('no service account')
    end
  end

  # A legacy row carrying only one rung stays EDITABLE — the missing slot is
  # built for the form. It does NOT silently complete the ladder: the built slot
  # has no credential, so submitting it unfilled returns 422 naming that rung.
  describe 'a legacy one-rung package' do
    it 'renders both slots on edit' do
      package = create(:ai_package)
      create(:ai_package_tier, ai_package: package, key: 'fast', position: 0,
                               label: AiPackageTier::DEFAULT_LABELS.fetch('fast'))
      log_in_admin

      get edit_admin_ai_package_path(package)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(AiPackageTier::DEFAULT_LABELS.fetch('thorough'))
      expect(response.body).not_to include('translation missing')
    end
  end

  describe 'an invalid PATCH re-renders instead of redirecting' do
    it 'answers 422 and leaves the record untouched' do
      package = create(:ai_package, :with_tiers)
      log_in_admin

      patch admin_ai_package_path(package), params: { ai_package: { name: '' } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(package.reload.name).to be_present
    end
  end
end
