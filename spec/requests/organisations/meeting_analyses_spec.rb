# frozen_string_literal: true

require 'rails_helper'

# MeetingAnalysesController + AnalysisPromptsController request specs (Gespräche
# Slice 7a). The security core: per-creator visibility in the rendered section, the
# AI gate trio, the D11 one-run-per-meeting idempotency, publish/unpublish flips,
# and the write gates (create/flip/destroy + prompt destroy need :meetings write).
# Denial surfaces as a redirect (area gate) or 404 (record scoped out), not a 403.
RSpec.describe 'Organisations::MeetingAnalyses', type: :request do
  let(:organisation) { create(:organisation, ai_enabled: true) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:meeting) do
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting, project: project, organisation: organisation, creator: writer, transcript: 'Gesprächstext.')
    end
  end

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
  let(:no_access_user) { user_with_access(:none) }

  # R2: the controller and the compose partial ask ai_available_for?(:meeting_analysis).
  # Stubbed at the ANSWER — a real Availability, built through the registry's own
  # struct — so the stub has the shape the call sites read (.available?), not a
  # boolean they would have to be rewritten for.
  #
  # SCOPED TO THE KEY, and that is the whole point. A stub without `with` answers for
  # every key, so a call site keyed to any other feature keeps passing — which makes
  # this file blind to the one defect R2 can introduce (measured: with a blanket stub,
  # retyping the controller's key to :chat left 113 examples green). Foreign keys fall
  # through to the real registry, and the test org has no usable credential, so a
  # mis-keyed gate resolves to "unavailable" and the positive examples below go red.
  def stub_ai_availability(available, reason: nil, feature: :meeting_analysis)
    allow_any_instance_of(Organisation).to receive(:ai_available_for?).and_call_original
    allow_any_instance_of(Organisation).to receive(:ai_available_for?).with(feature).and_return(
      Lalabase::Llm::FeatureRegistry::Availability.new(available: available, reason: reason)
    )
  end

  # AI is available by default (opt-in + configured); the async job is stubbed so no
  # real LLM traffic and no dependence on after-commit enqueue timing.
  before do
    stub_ai_availability(true)
    allow(Meetings::AnalysisJob).to receive(:perform_later)
    allow(EmbeddingProcessingJob).to receive(:perform_later)
  end

  def analysis_for(creator:, **attrs)
    ActsAsTenant.with_tenant(organisation) { create(:meeting_analysis, meeting: meeting, creator: creator, **attrs) }
  end

  def grant_assistant_access(user)
    organisation.update!(assistant_enabled: true)
    in_org do
      role = Membership.find_by!(organisation: organisation, user: user).role
      create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
    end
  end

  # require_tenant = true: model queries in the example body (outside the request's
  # own tenant scope) need an explicit tenant, exactly like meetings_spec.
  def in_org(&block)
    ActsAsTenant.with_tenant(organisation, &block)
  end

  # Stored results stay in the meeting flow. The legacy create endpoint remains
  # covered below for deployment compatibility, but has no current meeting UI.
  def get_flow(mtg = meeting, org = organisation, proj = project)
    get organisation_project_meeting_path(org, proj, mtg)
  end

  describe 'visibility in the results (flow)' do
    it 'shows the creator their own private analysis' do
      analysis_for(creator: writer, is_private: true, prompt_title: 'GEHEIME_ANALYSE')
      sign_in writer
      get_flow
      expect(response.body).to include('GEHEIME_ANALYSE')
    end

    it 'hides a foreign private analysis from another meetings-reader' do
      analysis_for(creator: writer, is_private: true, prompt_title: 'GEHEIME_ANALYSE')
      sign_in reader
      get_flow
      expect(response.body).not_to include('GEHEIME_ANALYSE')
    end

    it 'shows a published analysis to another meetings-reader' do
      analysis_for(creator: writer, is_private: false, prompt_title: 'OEFFENTLICHE_ANALYSE')
      sign_in reader
      get_flow
      expect(response.body).to include('OEFFENTLICHE_ANALYSE')
    end
  end

  # The entry button of the analyses frame, found by its label. Asserted on the parsed
  # element, never on a markup regex: every Neo button carries Tailwind "disabled:"
  # classes, so /<button[^>]*disabled/ matched an ENABLED button just as well.
  def analyses_entry_button(mtg = meeting)
    frame = Nokogiri::HTML(response.body).at_css("##{ActionView::RecordIdentifier.dom_id(mtg, :analyses)}")
    frame&.css('button')&.find { |button| button.text.squish == I18n.t('views.organisations.meetings.analyses.create_with_assistant') }
  end

  def analyses_frame_text(mtg = meeting)
    Nokogiri::HTML(response.body).at_css("##{ActionView::RecordIdentifier.dom_id(mtg, :analyses)}")&.text.to_s.squish
  end

  describe 'stored results without the legacy creation surfaces' do
    it 'renders result rows in the desktop flow without an analyses lane or create form' do
      analysis_for(creator: writer, is_private: false, prompt_title: 'FLOW_ANALYSE')
      sign_in writer
      get organisation_project_meeting_path(organisation, project, meeting)
      expect(response.body).to include('FLOW_ANALYSE')
      expect(response.body).not_to include('meeting_analyses_lane')
      expect(response.body).not_to include("action=\"#{organisation_project_meeting_analyses_path(organisation, project, meeting)}\"")
    end

    it 'renders results on mobile without the old inline compose form' do
      analysis_for(creator: writer, is_private: false, prompt_title: 'MOBILE_ANALYSE')
      sign_in writer
      get organisation_project_meeting_path(organisation, project, meeting, viewport: 'mobile')
      expect(response.body).to include('MOBILE_ANALYSE')
      expect(response.body).not_to include("action=\"#{organisation_project_meeting_analyses_path(organisation, project, meeting)}\"")
      expect(response.body).not_to include('meeting_analyses_lane')
    end

    it 'keeps stored results readable and disables creation when assistant AI is unavailable' do
      analysis_for(creator: writer, is_private: false, prompt_title: 'OFFLINE_ANALYSE')
      grant_assistant_access(writer)
      stub_ai_availability(false, reason: 'offline', feature: :chat)
      sign_in writer

      get_flow

      expect(response.body).to include('OFFLINE_ANALYSE')
      expect(analyses_frame_text).to include(I18n.t('views.organisations.meetings.analyses.assistant_unavailable'))
      button = analyses_entry_button
      expect(button).to be_present
      expect(button.key?('disabled')).to be(true)
      expect(button['data-assistant-trigger-intent-value']).to be_nil
      expect(button['title']).to be_nil # the enabled action's description must not stand on a dead button
    end

    # One coherent message: the no-source reason REPLACES the empty-list line, whose
    # "answers from the assistant appear here" would contradict a disabled entry.
    it 'shows only the no-source reason, not the empty line, and disables creation' do
      blank_meeting = in_org do
        create(:meeting, project: project, organisation: organisation, creator: writer)
      end
      grant_assistant_access(writer)
      stub_ai_availability(true, feature: :chat)
      sign_in writer

      get_flow(blank_meeting)

      text = analyses_frame_text(blank_meeting)
      expect(text).to include(I18n.t('views.organisations.meetings.analyses.no_content_hint'))
      expect(text).not_to include(I18n.t('views.organisations.meetings.analyses.empty_saved'))
      button = analyses_entry_button(blank_meeting)
      expect(button.key?('disabled')).to be(true)
      expect(button['data-assistant-trigger-intent-value']).to be_nil
    end

    # The positive half of the two disabled examples above, and stubbed on :chat ONLY:
    # the before block's :meeting_analysis stub is replaced, so the key falls through to
    # the real registry (unavailable for this org). An entry keyed to the feature instead
    # of the assistant's own rung goes red here.
    it 'enables the entry on the chat rung alone for a meeting with a source' do
      grant_assistant_access(writer)
      stub_ai_availability(true, feature: :chat)
      sign_in writer

      get_flow

      button = analyses_entry_button
      expect(button).to be_present
      expect(button.key?('disabled')).to be(false)
      expect(button['data-assistant-trigger-intent-value']).to eq('analysis')
      expect(analyses_frame_text).to include(I18n.t('views.organisations.meetings.analyses.empty_saved'))
    end

    # Rollout decision A: creation is assistant-only, but a writer in an AI org whose
    # assistant gate is closed is told so instead of the section silently vanishing.
    describe 'with the assistant gate closed' do
      it 'tells a writer where creation went, without an entry button or the empty line' do
        sign_in writer # org AI on, assistant flag off (default), no use_assistant

        get_flow

        text = analyses_frame_text
        expect(text).to include(I18n.t('views.organisations.meetings.analyses.assistant_not_enabled'))
        expect(text).not_to include(I18n.t('views.organisations.meetings.analyses.empty_saved'))
        expect(analyses_entry_button).to be_nil
        expect(response.body).not_to include('data-assistant-trigger-intent-value="analysis"')
      end

      it 'keeps stored analyses next to the hint' do
        analysis_for(creator: writer, is_private: false, prompt_title: 'GATE_ANALYSE')
        sign_in writer

        get_flow

        expect(analyses_frame_text).to include('GATE_ANALYSE', I18n.t('views.organisations.meetings.analyses.assistant_not_enabled'))
      end

      it 'says nothing to a reader, who could not create either way' do
        sign_in reader
        get_flow
        expect(response.body).not_to include(I18n.t('views.organisations.meetings.analyses.assistant_not_enabled'))
      end

      it 'says nothing in an org without AI, where the assistant is not the missing piece' do
        organisation.update!(ai_enabled: false)
        sign_in writer
        get_flow
        expect(response.body).not_to include(I18n.t('views.organisations.meetings.analyses.assistant_not_enabled'))
      end
    end

    it 'keeps results but not the compose form in a mobile meeting-update stream' do
      analysis_for(creator: writer, is_private: false, prompt_title: 'MOBILE_EDIT_ANALYSE')
      sign_in writer
      patch organisation_project_meeting_path(organisation, project, meeting, viewport: 'mobile'),
            params: { meeting: { title: 'Neuer Titel' } }, as: :turbo_stream
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('MOBILE_EDIT_ANALYSE')
      expect(response.body).not_to include("action=\"#{organisation_project_meeting_analyses_path(organisation, project, meeting)}\"")
    end

    it 'renders results without a create form in the desktop meeting-update stream' do
      analysis_for(creator: writer, is_private: false, prompt_title: 'DESKTOP_EDIT_ANALYSE')
      sign_in writer
      patch organisation_project_meeting_path(organisation, project, meeting),
            params: { meeting: { title: 'Neuer Titel' } }, as: :turbo_stream
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('DESKTOP_EDIT_ANALYSE') # results render in the flow
      expect(response.body).not_to include("action=\"#{organisation_project_meeting_analyses_path(organisation, project, meeting)}\"")
    end
  end

  describe 'POST create' do
    before { grant_assistant_access(writer) }

    it 'creates a pending analysis for a writer with a free-text prompt' do
      sign_in writer
      expect do
        post organisation_project_meeting_analyses_path(organisation, project, meeting),
             params: { meeting_analysis: { prompt_text: 'Fasse die Entscheidungen zusammen.' } },
             as: :turbo_stream
      end.to change { in_org { meeting.meeting_analyses.count } }.by(1)

      expect(response).to have_http_status(:ok)
      analysis = in_org { meeting.meeting_analyses.order(:created_at).last }
      expect(analysis.creation_flag).to be(true)
      expect(analysis.creator).to eq(writer)
      expect(analysis).to be_is_private
    end

    it 'redirects a reader (write gate) without creating anything' do
      sign_in reader
      expect do
        post organisation_project_meeting_analyses_path(organisation, project, meeting),
             params: { meeting_analysis: { prompt_text: 'x' } }
      end.not_to(change { in_org { meeting.meeting_analyses.count } })
      expect(response).to have_http_status(:redirect)
    end

    it 'refuses (403) a legacy create request after assistant access was revoked' do
      revoked_writer = user_with_access('read_write')
      sign_in revoked_writer

      expect do
        post organisation_project_meeting_analyses_path(organisation, project, meeting),
             params: { meeting_analysis: { prompt_text: 'x' } }, as: :turbo_stream
      end.not_to(change { in_org { meeting.meeting_analyses.count } })

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include(I18n.t('flash.meeting_analyses.assistant_unavailable'))
      expect(Meetings::AnalysisJob).not_to have_received(:perform_later)
    end

    it 'rejects (422) when the meeting has no notes or transcript' do
      blank_meeting = in_org do
        create(:meeting, project: project, organisation: organisation, creator: writer)
      end
      sign_in writer
      post organisation_project_meeting_analyses_path(organisation, project, blank_meeting),
           params: { meeting_analysis: { prompt_text: 'x' } }, as: :turbo_stream
      expect(response).to have_http_status(:unprocessable_content)
      expect(in_org { blank_meeting.meeting_analyses.count }).to eq(0)
    end

    # D11: one run per meeting at a time.
    it 'rejects a second create (422) while an analysis is already running, without a second row' do
      analysis_for(creator: writer, creation_flag: true) # running
      sign_in writer
      post organisation_project_meeting_analyses_path(organisation, project, meeting),
           params: { meeting_analysis: { prompt_text: 'x' } }, as: :turbo_stream
      expect(response).to have_http_status(:unprocessable_content)
      expect(in_org { meeting.meeting_analyses.count }).to eq(1)
    end

    it 'saves the free-text prompt to the org library when asked' do
      sign_in writer
      expect do
        post organisation_project_meeting_analyses_path(organisation, project, meeting),
             params: { meeting_analysis: { prompt_text: 'Wiederverwendbar.', save_as_template: '1' } },
             as: :turbo_stream
      end.to change { in_org { AnalysisPrompt.count } }.by(1)
    end
  end

  describe 'PATCH update (publish/unpublish flip)' do
    it 'publishes a private analysis for a writer' do
      analysis = analysis_for(creator: writer, is_private: true)
      sign_in writer
      patch organisation_project_meeting_analysis_path(organisation, project, meeting, analysis),
            params: { meeting_analysis: { is_private: 'false' } }, as: :turbo_stream
      expect(response).to have_http_status(:ok)
      expect(in_org { analysis.reload.is_private }).to be(false)
    end

    it 'rejects a flip (422) while the analysis is still running' do
      analysis = analysis_for(creator: writer, is_private: true, creation_flag: true)
      sign_in writer
      patch organisation_project_meeting_analysis_path(organisation, project, meeting, analysis),
            params: { meeting_analysis: { is_private: 'false' } }, as: :turbo_stream
      expect(response).to have_http_status(:unprocessable_content)
      expect(in_org { analysis.reload.is_private }).to be(true)
    end

    it 'reruns a failed analysis on its snapshot' do
      analysis = analysis_for(creator: writer, is_private: true, creation_flag: false, creation_error: 'kaputt')
      grant_assistant_access(writer)
      sign_in writer
      patch organisation_project_meeting_analysis_path(organisation, project, meeting, analysis),
            params: { meeting_analysis: { rerun: '1' } }, as: :turbo_stream
      expect(response).to have_http_status(:ok)
      reloaded = in_org { analysis.reload }
      expect(reloaded.creation_flag).to be(true)
      expect(reloaded.creation_error).to eq('')
    end

    # The retry replaces only the analyses frame. The creator-scoped subscription must
    # come back WITH it, or the completion broadcast has no listener and the spinner
    # this response shows never settles.
    it 'subscribes the replaced frame to the creator stream on rerun' do
      analysis = analysis_for(creator: writer, is_private: true, creation_flag: false, creation_error: 'kaputt')
      grant_assistant_access(writer)
      sign_in writer
      patch organisation_project_meeting_analysis_path(organisation, project, meeting, analysis),
            params: { meeting_analysis: { rerun: '1' } }, as: :turbo_stream
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<turbo-cable-stream-source')
    end

    it 'refuses (403) a rerun for a meetings writer without assistant permission' do
      # Published: a private analysis of somebody else is refused earlier, by
      # MeetingAnalysisPolicy#update?. This example is about the assistant gate.
      analysis = analysis_for(creator: writer, is_private: false, creation_flag: false, creation_error: 'kaputt')
      grant_assistant_access(writer) # org flag on; the second writer lacks use_assistant
      revoked_writer = user_with_access('read_write')
      sign_in revoked_writer

      patch organisation_project_meeting_analysis_path(organisation, project, meeting, analysis),
            params: { meeting_analysis: { rerun: '1' } }, as: :turbo_stream

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include(I18n.t('flash.meeting_analyses.assistant_unavailable'))
      reloaded = in_org { analysis.reload }
      expect(reloaded.creation_flag).to be(false)
      expect(reloaded.creation_error).to eq('kaputt')
      expect(Meetings::AnalysisJob).not_to have_received(:perform_later)
    end
  end

  # The retry button starts a new run, and runs belong to the assistant since #817: it
  # is offered only while the assistant gate is open (the server refuses it otherwise).
  describe 'retry button on a failed analysis' do
    def retry_button_for(analysis)
      row = Nokogiri::HTML(response.body).at_css("##{ActionView::RecordIdentifier.dom_id(analysis)}")
      row.css('button').find { |button| button.text.squish == I18n.t('views.organisations.meetings.analyses.retry') }
    end

    let!(:failed) { analysis_for(creator: writer, is_private: true, creation_flag: false, creation_error: 'kaputt') }

    it 'is hidden while the assistant gate is closed' do
      sign_in writer
      get_flow
      expect(retry_button_for(failed)).to be_nil
    end

    it 'is shown while the assistant gate is open' do
      grant_assistant_access(writer)
      sign_in writer
      get_flow
      expect(retry_button_for(failed)).to be_present
    end
  end

  describe 'GET legacy lane fallback' do
    it 'keeps old lazy requests navigable without restoring the retired composer' do
      sign_in writer
      get lane_organisation_project_meeting_analyses_path(organisation, project, meeting)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('meeting_analyses_lane', I18n.t('views.organisations.meetings.analyses.legacy_lane_moved'))
      expect(response.body).not_to include('meeting_analysis[prompt_text]')
    end

    it 'redirects a user without meetings access (area gate)' do
      sign_in no_access_user
      get lane_organisation_project_meeting_analyses_path(organisation, project, meeting)

      expect(response).to have_http_status(:redirect)
      expect(response.body).not_to include('meeting_analyses_lane')
    end
  end

  # Slice 7b: the search & chat release toggle. Only offered once published (disabled
  # hint while private); releasing enqueues the embedding, de-indexing purges it.
  # Review of #363, finding 2, second half: on an unexpected error in production the
  # actor returns a failure result with the RAW exception text. A
  # PG::NotNullViolation prints the whole offending row, and it stood on the screen
  # as a flash. The controller now masks :internal_error, as
  # TimeSessionGroupsController has done for some time.
  describe 'an internal error never reaches the flash' do
    it 'shows the generic message instead of the raw exception text' do
      analysis = analysis_for(creator: writer, is_private: false)
      raw = 'PG::NotNullViolation: ERROR: null value in column "include_in_search" ' \
            'Failing row contains (geheime Analyse, ...).'
      allow(Actors::SaveMeetingAnalysis).to receive(:call)
        .and_return(Actors::BaseActor::Result.new(success: false, errors: [raw], code: :internal_error))

      sign_in writer
      patch organisation_project_meeting_analysis_path(organisation, project, meeting, analysis),
            params: { meeting_analysis: { include_in_search: '1' } }, as: :turbo_stream

      expect(response.body).not_to include('Failing row contains')
      expect(response.body).to include(I18n.t('flash.meeting_analyses.error'))
    end
  end

  describe 'search & chat release (Slice 7b)' do
    def frag_for(analysis)
      in_org do
        create(:fragment, fragmentable: analysis, organisation: organisation,
                          plain_text_content: 'analyse fragment')
      end
    end

    describe 'toggle rendering (published-only)' do
      # The row now renders in the flow amid the rest of the meeting detail — which has
      # its OWN meeting-level search toggle sharing these labels — so scope assertions to
      # the analysis's own <li> to keep them honest. Labels contain "&" (→ &amp;), so
      # unescape the extracted fragment.
      def analysis_row_text(analysis)
        node = Nokogiri::HTML(response.body).at_css("##{ActionView::RecordIdentifier.dom_id(analysis)}")
        CGI.unescapeHTML(node.to_html)
      end

      it 'shows a locked hint (no release button) while the analysis is private' do
        analysis = analysis_for(creator: writer, is_private: true, prompt_title: 'PRIV_ANALYSE')
        sign_in writer
        get_flow
        row = analysis_row_text(analysis)
        expect(row).to include(I18n.t('views.organisations.meetings.analyses.search_locked_hint'))
        expect(row).not_to include(I18n.t('views.organisations.meetings.analyses.search_enable'))
      end

      it 'shows the release button for a published, not-yet-released analysis' do
        analysis = analysis_for(creator: writer, is_private: false, include_in_search: false, prompt_title: 'PUB_ANALYSE')
        sign_in writer
        get_flow
        expect(analysis_row_text(analysis)).to include(I18n.t('views.organisations.meetings.analyses.search_enable'))
      end

      it 'shows the search badge + remove button for a released analysis' do
        analysis = analysis_for(creator: writer, is_private: false, include_in_search: true, prompt_title: 'IDX_ANALYSE')
        sign_in writer
        get_flow
        row = analysis_row_text(analysis)
        expect(row).to include(I18n.t('views.organisations.meetings.analyses.search_on_badge'))
        expect(row).to include(I18n.t('views.organisations.meetings.analyses.search_disable'))
      end
    end

    it 'releases a published analysis to search and enqueues the embedding' do
      analysis = analysis_for(creator: writer, is_private: false, include_in_search: false, content: 'body')
      sign_in writer
      patch organisation_project_meeting_analysis_path(organisation, project, meeting, analysis),
            params: { meeting_analysis: { include_in_search: 'true' } }, as: :turbo_stream
      expect(response).to have_http_status(:ok)
      expect(in_org { analysis.reload.include_in_search }).to be(true)
      expect(EmbeddingProcessingJob).to have_received(:perform_later).with(
        record_class: MeetingAnalysis, record_id: analysis.id, fragment_association: :fragments
      )
    end

    # 4A over the endpoint: unpublishing a search-released analysis clears the release
    # AND purges its fragments; a later re-publish does NOT auto-index.
    it 'unpublishing clears the release, purges fragments, and does not re-index on re-publish' do
      analysis = analysis_for(creator: writer, is_private: false, include_in_search: true,
                              content: 'body', embeddings_creation_flag: true)
      frag_for(analysis)
      sign_in writer

      patch organisation_project_meeting_analysis_path(organisation, project, meeting, analysis),
            params: { meeting_analysis: { is_private: 'true' } }, as: :turbo_stream
      reloaded = in_org { analysis.reload }
      expect(reloaded.is_private).to be(true)
      expect(reloaded.include_in_search).to be(false)
      expect(in_org { analysis.fragments.count }).to eq(0)

      patch organisation_project_meeting_analysis_path(organisation, project, meeting, analysis),
            params: { meeting_analysis: { is_private: 'false' } }, as: :turbo_stream
      expect(in_org { analysis.reload.include_in_search }).to be(false)
    end

    it 'toggling search off keeps the analysis published (no implicit unpublish)' do
      analysis = analysis_for(creator: writer, is_private: false, include_in_search: true, content: 'body')
      sign_in writer
      patch organisation_project_meeting_analysis_path(organisation, project, meeting, analysis),
            params: { meeting_analysis: { include_in_search: 'false' } }, as: :turbo_stream
      reloaded = in_org { analysis.reload }
      expect(reloaded.include_in_search).to be(false)
      expect(reloaded.is_private).to be(false)
    end

    it 'redirects a reader (write gate) without releasing' do
      analysis = analysis_for(creator: writer, is_private: false, include_in_search: false)
      sign_in reader
      patch organisation_project_meeting_analysis_path(organisation, project, meeting, analysis),
            params: { meeting_analysis: { include_in_search: 'true' } }
      expect(response).to have_http_status(:redirect)
      expect(in_org { analysis.reload.include_in_search }).to be(false)
    end
  end

  describe 'DELETE destroy' do
    it 'deletes an analysis for a writer' do
      analysis = analysis_for(creator: writer, is_private: false)
      sign_in writer
      expect do
        delete organisation_project_meeting_analysis_path(organisation, project, meeting, analysis), as: :turbo_stream
      end.to change { in_org { meeting.meeting_analyses.count } }.by(-1)
      expect(response).to have_http_status(:ok)
    end

    it 'redirects a reader (write gate) without deleting' do
      analysis = analysis_for(creator: writer, is_private: false)
      sign_in reader
      expect do
        delete organisation_project_meeting_analysis_path(organisation, project, meeting, analysis)
      end.not_to(change { in_org { meeting.meeting_analyses.count } })
      expect(response).to have_http_status(:redirect)
    end

    it '404s for an analysis of another meeting (cross-scope)' do
      other_meeting = in_org do
        create(:meeting, project: project, organisation: organisation, creator: writer)
      end
      foreign = in_org { create(:meeting_analysis, meeting: other_meeting, creator: writer) }
      sign_in writer
      delete organisation_project_meeting_analysis_path(organisation, project, meeting, foreign)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'DELETE analysis_prompts (6A)' do
    it 'deletes an org prompt for a writer' do
      prompt = in_org { create(:analysis_prompt, organisation: organisation, creator: writer) }
      sign_in writer
      expect do
        delete organisation_project_meeting_analysis_prompt_path(organisation, project, meeting, prompt), as: :turbo_stream
      end.to change { in_org { AnalysisPrompt.count } }.by(-1)
      expect(response).to have_http_status(:ok)
    end

    it 'redirects a reader (write gate) without deleting the prompt' do
      prompt = in_org { create(:analysis_prompt, organisation: organisation, creator: writer) }
      sign_in reader
      expect do
        delete organisation_project_meeting_analysis_prompt_path(organisation, project, meeting, prompt)
      end.not_to(change { in_org { AnalysisPrompt.count } })
      expect(response).to have_http_status(:redirect)
    end
  end

  # The legacy write routes may still receive requests during a rolling deploy, but
  # they must only refresh the stored-results frame and never resurrect compose UI.
  describe 'turbo-stream frame targeting' do
    before { grant_assistant_access(writer) }

    def results_target
      "target=\"#{ActionView::RecordIdentifier.dom_id(meeting, :analyses)}\""
    end

    it 'refreshes only the results frame on legacy create' do
      sign_in writer
      post organisation_project_meeting_analyses_path(organisation, project, meeting),
           params: { meeting_analysis: { prompt_text: 'x' } }, as: :turbo_stream
      expect(response.body).to include(results_target)
      expect(response.body).not_to include('analyses_compose')
    end

    it 'refreshes only the results frame on a publish flip' do
      analysis = analysis_for(creator: writer, is_private: true)
      sign_in writer
      patch organisation_project_meeting_analysis_path(organisation, project, meeting, analysis),
            params: { meeting_analysis: { is_private: 'false' } }, as: :turbo_stream
      expect(response.body).to include(results_target)
      expect(response.body).not_to include('analyses_compose')
    end

    it 'refreshes only the results frame on destroy' do
      analysis = analysis_for(creator: writer, is_private: false)
      sign_in writer
      delete organisation_project_meeting_analysis_path(organisation, project, meeting, analysis), as: :turbo_stream
      expect(response.body).to include(results_target)
      expect(response.body).not_to include('analyses_compose')
    end

    it 'accepts a stale lane discard without rendering the removed frame' do
      analysis = analysis_for(creator: writer, is_private: true)
      sign_in writer
      delete organisation_project_meeting_analysis_path(organisation, project, meeting, analysis),
             params: { surface: 'compose' }, as: :turbo_stream
      expect(response.body).to include(results_target)
      expect(response.body).not_to include('analyses_compose')
      expect(in_org { MeetingAnalysis.exists?(analysis.id) }).to be(false)
    end

    it 'accepts a stale nested template delete without rendering the removed frame' do
      prompt = in_org { create(:analysis_prompt, organisation: organisation, creator: writer) }
      sign_in writer
      delete organisation_project_meeting_analysis_prompt_path(organisation, project, meeting, prompt), as: :turbo_stream
      expect(response.body).not_to include(results_target)
      expect(response.body).not_to include('analyses_compose')
    end
  end

  # Live-Cockpit (Option A): the finished analysis is pushed to the creator without a
  # manual refresh. The stream MUST be creator-scoped — a meeting-wide stream would leak a
  # private analysis to every viewer of the meeting (the whole reason the section had no
  # broadcast before). And it must only fire on genuine completion, not on every update.
  describe 'completion broadcast (creator-scoped)' do
    it 'does not send a late private result after the creator loses meeting read access' do
      analysis = analysis_for(creator: writer, is_private: true, creation_flag: true)
      in_org { ProjectPermission.find_by!(user: writer, project: project).update!(meetings_access: 'no_access') }
      expect(analysis).not_to receive(:broadcast_replace_to)

      in_org { analysis.update!(creation_flag: false, content: 'PRIVATE_LATE_RESULT') }
      expect(analysis.reload.content).to eq('PRIVATE_LATE_RESULT')
    end

    it 'does not send a late result after the creator leaves the organisation' do
      analysis = analysis_for(creator: writer, is_private: true, creation_flag: true)
      expect(in_org { ProjectPolicy.new(analysis.creator, project).area_access?(:meetings, :read) }).to be true
      in_org { Membership.find_by!(user: writer, organisation: organisation).update!(active: false) }
      expect(analysis).not_to receive(:broadcast_replace_to)

      in_org { analysis.update!(creation_flag: false, content: 'PRIVATE_LATE_RESULT') }
    end

    it 'keeps a readable legacy result live after write access is revoked, without write actions' do
      analysis = analysis_for(creator: writer, is_private: true, creation_flag: true)
      in_org { ProjectPermission.find_by!(user: writer, project: project).update!(meetings_access: 'read_only') }
      expect(analysis).to receive(:broadcast_replace_to).with(
        meeting, writer, :analyses,
        hash_including(locals: hash_including(can_write: false))
      )

      in_org { analysis.update!(creation_flag: false, content: 'READABLE_LATE_RESULT') }
    end

    it 'pushes the results frame to the creator-scoped stream, never meeting-wide' do
      analysis = analysis_for(creator: writer, is_private: true, creation_flag: true)
      calls = []
      allow(analysis).to receive(:broadcast_replace_to) do |*streamables, **opts|
        calls << { streamables: streamables, target: opts[:target] }
      end

      in_org { analysis.update!(creation_flag: false, content: 'ERGEBNIS_X') }

      expect(calls.size).to eq(1)
      # creator-scoped, NOT [meeting, :analyses] (which every viewer would receive)
      calls.each { |c| expect(c[:streamables]).to eq([meeting, writer, :analyses]) }
      expect(calls.first[:target]).to eq(ActionView::RecordIdentifier.dom_id(meeting, :analyses_list))
    end

    it 'does not broadcast on a publish flip (no completion change)' do
      analysis = analysis_for(creator: writer, is_private: true) # settled (flag false)
      expect(analysis).not_to receive(:broadcast_replace_to)
      in_org { analysis.update!(is_private: false) }
    end

    it 'renders the result frame without request-only assistant helpers on completion' do
      analysis = analysis_for(creator: writer, is_private: true, creation_flag: true)
      expect do
        in_org { analysis.update!(creation_flag: false, content: 'ERGEBNIS_PREVIEW') }
      end.not_to raise_error
    end
  end

  describe 'performance' do
    it 'renders several analyses without an N+1 on creator/prompt (Prosopite guards it)' do
      # Prosopite scans every example (spec/support/prosopite.rb): drop
      # includes(:creator, :analysis_prompt) from visible_meeting_analyses and loading
      # N creators/prompts becomes an N+1 that fails THIS example. Three distinct
      # creators/prompts are needed — one row could never surface it.
      titles = ActsAsTenant.with_tenant(organisation) do
        Array.new(3) do |i|
          prompt = create(:analysis_prompt, organisation: organisation, creator: writer)
          # Distinct creators (bare :user, no membership) so includes(:creator) is
          # what's under test — not a factory-setup membership load.
          create(:meeting_analysis, meeting: meeting, is_private: false, analysis_prompt: prompt,
                                    creator: create(:user), prompt_title: "ANALYSE_#{i}")
          "ANALYSE_#{i}"
        end
      end
      sign_in writer

      get_flow
      expect(response).to have_http_status(:ok)
      titles.each { |title| expect(response.body).to include(title) }
    end
  end
end
