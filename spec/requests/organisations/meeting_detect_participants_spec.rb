# frozen_string_literal: true

require 'rails_helper'

# detect_participants endpoint (Gespräche Slice 5) — the mandatory guard trio
# (plan §5 / Eng-Review D5+D9) plus the most important negative path:
#
#   1. no org AI opt-in            → 403, Factory NEVER touched (fail-closed)
#   2. payload over the byte cap   → 422 with a readable message, no Factory
#   3. throttle exceeded           → 429 (Rack::Attack, per user)
#   4. ORG GATE BEATS USER SETTING → user preference 'ai' changes NOTHING about 1.
#
# Plus: reader (meetings read-only) is denied by Pundit BEFORE any LLM work
# (denial surfaces as the app-wide redirect convention, not a literal 403 —
# the explicit 403 is reserved for the AI gate's JSON answer), and the happy
# path returns the detected names as JSON. All LLM traffic stubbed at the
# Factory/provider seam — no real call ever leaves the suite.
RSpec.describe 'Organisations::Meetings detect_participants', type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  # Builds a signed-up user whose meetings access on `project` is `level`
  # ('read_only' / 'read_write'), or :none for no access at all.
  # Deliberate twin of the helper in meetings_spec.rb (suite convention).
  def user_with_access(level, on: project)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      create(:project_permission, user: user, project: on, meetings_access: level) unless level == :none
    end
    user
  end

  let(:writer) { user_with_access('read_write') }
  let(:reader) { user_with_access('read_only') }

  let(:detect_path) { detect_participants_organisation_project_meetings_path(organisation, project) }
  let(:transcript) { "**Anna Ananas:** Hallo.\n**Bert Bauer:** Guten Morgen." }

  def post_detect(text = transcript)
    post detect_path, params: { transcript: text }, headers: { 'Accept' => 'application/json' }
  end

  describe 'AI gate (fail-closed, plan trio 1)' do
    it 'answers 403 without touching the LLM seam when the org has not opted in' do
      organisation.update!(ai_enabled: false) # factory default is opted-in
      expect(Lalabase::Llm::Factory).not_to receive(:build)

      sign_in writer
      post_detect

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body['error'])
        .to eq(I18n.t('services.meetings.participant_detection.ai_unavailable'))
    end

    it 'answers 403 when the org opted in but has no usable configuration (ai_available? is the gate)' do
      organisation.update!(ai_enabled: true)
      allow_any_instance_of(Organisation).to receive(:has_valid_ai_configuration?).and_return(false)
      expect(Lalabase::Llm::Factory).not_to receive(:build)

      sign_in writer
      post_detect

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'org gate beats user setting (plan §5, most important negative path)' do
    it "answers 403 and never touches the Factory even when the user's detection mode is 'ai'" do
      organisation.update!(ai_enabled: false)
      writer.preference_store.set!('meeting_detection_mode', 'ai')
      expect(Lalabase::Llm::Factory).not_to receive(:build)

      sign_in writer
      post_detect

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'payload cap (plan trio 2)' do
    before do
      organisation.update!(ai_enabled: true)
      allow_any_instance_of(Organisation).to receive(:has_valid_ai_configuration?).and_return(true)
    end

    it 'answers 422 with a readable message and no LLM call for an oversized transcript' do
      expect(Lalabase::Llm::Factory).not_to receive(:build)

      sign_in writer
      post_detect('A' * (Organisations::MeetingsController::MAX_DETECT_BYTES + 1))

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to include('zu groß')
    end

    it 'answers 422 for a blank transcript (nothing to detect, no credits wasted)' do
      expect(Lalabase::Llm::Factory).not_to receive(:build)

      sign_in writer
      post_detect('   ')

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'authorization' do
    before do
      organisation.update!(ai_enabled: true)
      allow_any_instance_of(Organisation).to receive(:has_valid_ai_configuration?).and_return(true)
    end

    it 'denies a reader (meetings read-only) before any LLM work' do
      expect(Lalabase::Llm::Factory).not_to receive(:build)

      sign_in reader
      post_detect

      # detect_participants is in write_actions, so a reader is turned away at the
      # area gate (redirect) before Pundit even runs — the same visible outcome,
      # now double-gated (area gate + detect_participants? policy).
      expect(response).to have_http_status(:redirect)
    end

    it 'redirects a user without meetings access at the area gate' do
      expect(Lalabase::Llm::Factory).not_to receive(:build)

      sign_in user_with_access(:none)
      post_detect

      expect(response).to have_http_status(:redirect)
    end
  end

  describe 'detection (LLM stubbed at the seam)' do
    let(:provider) { double('llm_provider', provider_name: 'openai') }

    before do
      organisation.update!(ai_enabled: true)
      allow_any_instance_of(Organisation).to receive(:has_valid_ai_configuration?).and_return(true)
      allow(Lalabase::Llm::Factory).to receive(:build).and_return(provider)
      allow(Lalabase::Llm::UsageTracking).to receive(:record)
    end

    it 'returns the detected names as display_name JSON for a writer' do
      allow(provider).to receive(:chat).and_return(
        { content: '["Anna Ananas", "Bert Bauer"]', token_usage: { total_tokens: 21 }, model_used: 'gpt-4o-mini' }
      )

      sign_in writer
      post_detect

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['participants'])
        .to eq([{ 'display_name' => 'Anna Ananas' }, { 'display_name' => 'Bert Bauer' }])
    end

    it 'maps a service failure to 422 with the readable quota message' do
      allow(Lalabase::Llm::Factory).to receive(:build).and_raise(Lalabase::Llm::QuotaExceededError)

      sign_in writer
      post_detect

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error'])
        .to eq(I18n.t('services.meetings.participant_detection.quota_exceeded'))
    end

    it 'maps an unexpected service status to 422 with the generic error message' do
      # :error (the StandardError path) is NOT in DETECTION_ERROR_KEYS, so the
      # controller's fetch(..., 'generic_error') fallback answers — the only path
      # that reaches it.
      allow(Meetings::ParticipantDetectionService).to receive(:call)
        .and_return(Meetings::ParticipantDetectionService::Result.new(status: :error, participants: []))

      sign_in writer
      post_detect

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error'])
        .to eq(I18n.t('services.meetings.participant_detection.generic_error'))
    end
  end

  # Server-rendered form gating (plan D3 trio + decision 12): the AI surface is
  # decided on the server — without org opt-in neither button nor transmission
  # hint exists in the DOM (no "offer, then refuse"), regardless of the user's
  # detection-mode setting.
  describe 'form gating (server-rendered)' do
    def get_new_form(user)
      sign_in user
      get new_organisation_project_meeting_path(organisation, project, frame: 'content'),
          headers: { 'Turbo-Frame' => 'meeting_display_frame' }
    end

    it "renders neither AI button nor transmission hint without org opt-in — even with user mode 'ai'" do
      organisation.update!(ai_enabled: false) # factory default is opted-in
      writer.preference_store.set!('meeting_detection_mode', 'ai')

      get_new_form(writer)

      expect(response.body).not_to include(I18n.t('views.organisations.meetings.form.detect_button'))
      expect(response.body).not_to include(I18n.t('views.organisations.meetings.form.ai_mode_hint'))
      expect(response.body).not_to include('detect-url-value')
    end

    it 'renders a disabled AI button plus setup hint when opted in but not configured' do
      organisation.update!(ai_enabled: true)
      allow_any_instance_of(Organisation).to receive(:has_valid_ai_configuration?).and_return(false)

      get_new_form(writer)

      expect(response.body).to include(I18n.t('views.organisations.meetings.form.detect_button'))
      expect(response.body).to include(I18n.t('views.organisations.meetings.form.detect_setup_hint'))
      expect(response.body).not_to include('detect-url-value')
    end

    context 'when AI is available' do
      before do
        organisation.update!(ai_enabled: true)
        allow_any_instance_of(Organisation).to receive(:has_valid_ai_configuration?).and_return(true)
      end

      it 'renders the active AI button (offline mode) without setup hint or transmission hint' do
        get_new_form(writer)

        expect(response.body).to include(I18n.t('views.organisations.meetings.form.detect_button'))
        expect(response.body).to include('detect-url-value')
        expect(response.body).not_to include(I18n.t('views.organisations.meetings.form.detect_setup_hint'))
        expect(response.body).not_to include(I18n.t('views.organisations.meetings.form.ai_mode_hint'))
      end

      it 'renders the PERMANENT transmission hint with a settings link in AI mode (auto-detection replaces the button)' do
        writer.preference_store.set!('meeting_detection_mode', 'ai')

        get_new_form(writer)

        expect(response.body).to include(I18n.t('views.organisations.meetings.form.ai_mode_hint'))
        expect(response.body).to include(meetings_user_preferences_path)
        expect(response.body).to include('detection-mode-value="ai"')
        expect(response.body).not_to include(I18n.t('views.organisations.meetings.form.detect_button'))
      end
    end
  end

  # Plan trio 3: the endpoint is an unpersisted, repeatable LLM surface — the
  # per-user Rack::Attack throttle bounds it. Uses the real middleware with a
  # counting cache store (the test default :null_store never counts — the
  # admin/sessions F5 pattern).
  describe 'throttling (rack_attack meetings/detect_participants/user)' do
    around do |example|
      enabled_was = Rack::Attack.enabled
      store_was = Rack::Attack.cache.store
      Rack::Attack.enabled = true
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      example.run
      Prosopite.resume
      Rack::Attack.cache.store = store_was
      Rack::Attack.enabled = enabled_was
    end

    it 'lets 10 requests per minute through and answers 429 on the 11th, per user' do
      # 11 independent POSTs repeat the same auth lookups — a loop of separate
      # requests, not a request-scoped N+1; pause the per-example scan.
      Prosopite.pause

      sign_in writer
      10.times do
        post_detect
        expect(response).to have_http_status(:forbidden) # AI gate — but counted
      end

      post_detect
      expect(response).to have_http_status(:too_many_requests)

      # Per-user discriminator: another user is NOT throttled by writer's counter.
      other_writer = user_with_access('read_write')
      sign_in other_writer
      post_detect
      expect(response).to have_http_status(:forbidden)
    end

    it 'still throttles when a format suffix is appended (no .json bypass)' do
      # The route is detect_participants(.:format) and the action renders JSON
      # regardless — so the throttle must match the action, not the bare path.
      # A path-suffix matcher (end_with?) would skip .json and leave the paid
      # LLM endpoint unbounded per user.
      Prosopite.pause
      json_path = detect_participants_organisation_project_meetings_path(organisation, project, format: :json)

      sign_in writer
      10.times do
        post json_path, params: { transcript: transcript }, headers: { 'Accept' => 'application/json' }
        expect(response).to have_http_status(:forbidden) # AI gate — but counted
      end

      post json_path, params: { transcript: transcript }, headers: { 'Accept' => 'application/json' }
      expect(response).to have_http_status(:too_many_requests)
    end

    it 'throttles anonymous requests by IP (the || req.ip discriminator fallback)' do
      # No sign_in: warden has no user, so the discriminator falls back to req.ip.
      # Rack::Attack runs as middleware BEFORE the controller auth, so each
      # unauthenticated request is still counted (redirected, but counted).
      Prosopite.pause

      10.times { post_detect }
      expect(response).not_to have_http_status(:too_many_requests)

      post_detect
      expect(response).to have_http_status(:too_many_requests)
    end
  end

  # R2 (doc/ai_feature_registry_plan.md §6): the detect leg is keyed
  # :meeting_participant_detection at THREE places — the endpoint, the form partial
  # and the user preference — and the three must name the same row, because the
  # button the preference enables posts to the endpoint the partial renders.
  #
  # Why it needs its own block: every unpinned chat row answers identically today, so
  # a mis-keyed call site is invisible in production AND to every other example in
  # this file. Measured before this block existed: retyping all three to :chat left
  # 123 examples green. Refusing exactly one row is what makes the key visible.
  describe 'feature key (R2)' do
    before do
      organisation.update!(ai_enabled: true)
      allow_any_instance_of(Organisation).to receive(:has_valid_ai_configuration?).and_return(true)
    end

    def refuse_only(feature_key)
      allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).and_call_original
      allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).with(feature_key, anything).and_return(
        Lalabase::Llm::FeatureRegistry::Availability.new(available: false, reason: :no_credential)
      )
    end

    it 'takes down form and endpoint together when their OWN row says no' do
      refuse_only(:meeting_participant_detection)
      sign_in writer

      get new_organisation_project_meeting_path(organisation, project, frame: 'content'),
          headers: { 'Turbo-Frame' => 'meeting_display_frame' }
      expect(response.body).not_to include('detect-url-value')

      expect(Lalabase::Llm::Factory).not_to receive(:build)
      post_detect
      expect(response).to have_http_status(:forbidden)
    end

    # The other direction: without it, a gate that asked nothing at all — or answered
    # no for every key — would satisfy the example above and pin nothing.
    it 'leaves the detect leg alone when a foreign row says no' do
      refuse_only(:meeting_summary)
      sign_in writer

      get new_organisation_project_meeting_path(organisation, project, frame: 'content'),
          headers: { 'Turbo-Frame' => 'meeting_display_frame' }

      expect(response.body).to include('detect-url-value')
      expect(response.body).to include(I18n.t('views.organisations.meetings.form.detect_button'))
    end
  end

  # S1c (doc/ki_provider_reichweite_plan.md §2.1b) — the end-to-end proof, and the
  # only block here that stubs NEITHER the gate NOR the Factory. Everything above
  # stubs has_valid_ai_configuration?, so none of it would notice that the gate
  # answered for the wrong provider.
  #
  # Before S1c this org got a 403 and an empty DOM although S1 had already pointed
  # the routing at its endpoint: has_valid_ai_configuration? was `case provider …
  # else false`. Pin 'openai' back into either half — the gate or the routing —
  # and this block goes red.
  describe 'a non-OpenAI org reaches the feature at all (S1c)' do
    let(:organisation) do
      create(:organisation, ai_enabled: true, ai_provider: 'openai_compatible',
                            ai_access_token: 'sk-mistral-own-token-1234567890',
                            ai_api_base: 'https://api.mistral.ai/v1',
                            preferred_chat_model: 'mistral-small-latest')
    end
    let(:provider) { double('llm_provider', provider_name: 'openai_compatible') }

    before do
      # No usable OpenAI configuration anywhere — the org has only its own endpoint.
      allow(AiCredential).to receive(:active_for_provider).and_return(nil)
      allow(Lalabase::Llm::OpenAiCompatibleProvider).to receive(:new).and_return(provider)
      allow(Lalabase::Llm::OpenAiProvider).to receive(:new).and_return(provider)
      allow(Lalabase::Llm::UsageTracking).to receive(:record)
      allow(provider).to receive(:chat).and_return(
        { content: '["Anna Ananas"]', token_usage: { total_tokens: 21 }, model_used: 'mistral-small-latest' }
      )
    end

    it 'answers 200 and detects, routing to the org endpoint instead of OpenAI' do
      sign_in writer
      post_detect

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['participants']).to eq([{ 'display_name' => 'Anna Ananas' }])
      expect(Lalabase::Llm::OpenAiCompatibleProvider).to have_received(:new)
      expect(Lalabase::Llm::OpenAiProvider).not_to have_received(:new)
    end

    it 'renders the active AI button in the form (gate and routing agree)' do
      sign_in writer
      get new_organisation_project_meeting_path(organisation, project, frame: 'content'),
          headers: { 'Turbo-Frame' => 'meeting_display_frame' }

      expect(response.body).to include(I18n.t('views.organisations.meetings.form.detect_button'))
      expect(response.body).to include('detect-url-value')
      expect(response.body).not_to include(I18n.t('views.organisations.meetings.form.detect_setup_hint'))
    end
  end
end
