# frozen_string_literal: true

require 'rails_helper'

# toggle_search (Meeting-Such-Status): the one-click search & chat release flip
# plus the status badge/list column it drives. The flip MUST run through
# Actors::SaveMeeting — only the actor enqueues the embedding job on release and
# synchronously purges the fragments on de-index (PII) — so the specs pin the
# actor seam (a raw update_column would leak fragments) and the response
# contract: badge replace + list refresh WITH the forwarded filters. Denial
# surfaces as redirect/404, not a literal 403 (app convention, meetings_spec).
RSpec.describe 'Organisations::Meetings toggle_search', type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  # Builds a signed-up user whose meetings access on `project` is `level`
  # ('read_only' / 'read_write') — mirrors meetings_spec.rb.
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

  let(:meeting) do
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting, project: project, organisation: organisation, creator: writer,
                       title: 'Kickoff', transcript: 'Kunde will Feature X bis Q3.')
    end
  end

  let(:turbo_headers) { { 'Accept' => 'text/vnd.turbo-stream.html' } }

  def toggle_path(target = nil)
    toggle_search_organisation_project_meeting_path(organisation, project, target || meeting)
  end

  describe 'release (off → on)' do
    it 'flips the opt-in THROUGH the actor and streams badge + list + flash' do
      sign_in writer
      # Pins the write seam: the actor (not a raw column write) owns the
      # enqueue-on-release / purge-on-optout side effects (save_meeting.rb).
      expect(Actors::SaveMeeting).to receive(:new)
        .with(hash_including(id: meeting.id, params: { create_embeddings: true }))
        .and_call_original

      post toggle_path, params: { create_embeddings: '1' }, headers: turbo_headers

      expect(response).to have_http_status(:ok)
      expect(meeting.reload.create_embeddings).to be(true)
      expect(response.body).to include("meeting_#{meeting.id}_search_status")
      expect(response.body).to include('meetings_results')
      # Fragment WITHOUT the "&" — the flash text is HTML-escaped in the body.
      expect(response.body).to include('der Inhalt wird indexiert')
    end

    it 'rejects a release without content (422 hint, nothing changes)' do
      empty = ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation, creator: writer, title: 'Leer')
      end
      sign_in writer
      expect(Actors::SaveMeeting).not_to receive(:new)

      post toggle_path(empty), params: { create_embeddings: '1' }, headers: turbo_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(empty.reload.create_embeddings).to be(false)
    end
  end

  describe 'de-index (on → off)' do
    let(:meeting) do
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation, creator: writer,
                         title: 'Kickoff', transcript: 'Vertraulich.', create_embeddings: true)
      end
    end

    it 'clears the opt-in and purges the fragments synchronously (PII)' do
      ActsAsTenant.with_tenant(organisation) do
        meeting.fragments.create!(organisation: organisation, plain_text_content: 'Vertraulich.',
                                  version_token: SecureRandom.uuid)
      end
      sign_in writer

      post toggle_path, params: { create_embeddings: '0' }, headers: turbo_headers

      expect(response).to have_http_status(:ok)
      expect(meeting.reload.create_embeddings).to be(false)
      # Fragment queries are tenant-scoped (require_tenant).
      expect(ActsAsTenant.with_tenant(organisation) { meeting.fragments.count }).to eq(0)
      expect(response.body).to include(I18n.t('flash.meetings.search_disabled'))
    end
  end

  describe 'filter preservation (forwarded search param)' do
    it 're-renders the list frame with the active search filter still applied' do
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation, creator: writer,
                         title: 'Anderes Thema', notes: 'ohne Treffer')
      end
      sign_in writer

      post toggle_path, params: { create_embeddings: '1', search: 'Kickoff' }, headers: turbo_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Kickoff')
      # Without the filter forwarding the refreshed list would fall back to ALL
      # meetings — the foreign title showing up is exactly the regression.
      expect(response.body).not_to include('Anderes Thema')
    end
  end

  describe 'authorization & tenancy' do
    it 'denies a read-only user (redirect) and changes nothing' do
      sign_in reader
      post toggle_path, params: { create_embeddings: '1' }
      expect(response).to have_http_status(:redirect)
      expect(meeting.reload.create_embeddings).to be(false)
    end

    it '404s a meeting id from another project (set_meeting scope)' do
      other_project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      foreign = ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: other_project, organisation: organisation, creator: writer, title: 'Fremd')
      end
      sign_in writer
      post toggle_search_organisation_project_meeting_path(organisation, project, foreign),
           params: { create_embeddings: '1' }
      expect(response).to have_http_status(:not_found)
    end
  end

  # The badge/column render gate (plan D-2): visible only with org AI enabled.
  describe 'status surfaces in show + list' do
    def show_detail(user)
      sign_in user
      get organisation_project_meeting_path(organisation, project, meeting, frame: 'content'),
          headers: { 'Turbo-Frame' => 'meeting_display_frame' }
    end

    context 'with org AI enabled' do
      before { organisation.update!(ai_enabled: true) }

      it 'shows the badge and the release action to a writer' do
        show_detail(writer)
        expect(response.body).to include(I18n.t('views.organisations.meetings.search_status.label_off'))
        expect(response.body).to include(toggle_path)
      end

      it 'shows the badge without the toggle to a read-only user' do
        show_detail(reader)
        expect(response.body).to include(I18n.t('views.organisations.meetings.search_status.label_off'))
        expect(response.body).not_to include(toggle_path)
      end
    end

    context 'with org AI disabled' do
      # The organisation factory defaults to ai_enabled: true — switch it OFF
      # explicitly to exercise the D-2 gate on the detail badge.
      before { organisation.update!(ai_enabled: false) }

      it 'renders no search-status badge in the detail' do
        show_detail(writer)
        expect(response.body).not_to include("meeting_#{meeting.id}_search_status")
      end
    end
  end

  # R3 (doc/ai_feature_registry_plan.md §2.2/§2.3): the badge describes the EMBEDDING
  # lane, and now asks it. Until R3 it called org.ai_available? with no argument at
  # all — whose default parameter is 'openai', a seventh pin invisible to any grep
  # for the literal — and so answered an embedding question out of the CHAT columns.
  #
  # Only one branch of meeting_search_status reads the flag (released for search,
  # not yet indexed), which is exactly where the two answers diverge:
  # "wird vorbereitet" vs. "wartet auf KI-Konfiguration".
  describe 'the search badge asks the embedding lane (R3)' do
    let(:released) do
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation, creator: writer,
                         title: 'Freigegeben', transcript: 'Inhalt', create_embeddings: true)
      end
    end

    def badge_for(target)
      sign_in writer
      get organisation_project_meeting_path(organisation, project, target, frame: 'content'),
          headers: { 'Turbo-Frame' => 'meeting_display_frame' }
      response.body
    end

    def label(status)
      I18n.t("views.organisations.meetings.search_status.label_#{status}")
    end

    # THE behaviour change. Before R3 this org's chat configuration made the badge
    # claim "wird für Suche vorbereitet" while nothing could ever index it — the
    # embedding lane has no credential at all. The badge now says so.
    it 'waits for configuration when only the CHAT lane is configured' do
      allow(AiCredential).to receive(:active_for_provider).and_return(nil)
      organisation.update!(ai_enabled: true, ai_provider: 'openai',
                           ai_access_token: 'sk-org-own-1234567890abcdef')

      body = badge_for(released)

      expect(body).to include(label(:waiting_ai))
      expect(body).not_to include(label(:processing))
    end

    it 'reports preparation once the EMBEDDING lane is configured' do
      allow(AiCredential).to receive(:active_for_provider).and_return(nil)
      organisation.update!(ai_enabled: true, ai_provider: 'openai',
                           embedding_access_token: 'sk-org-own-embed-1234567890')

      body = badge_for(released)

      expect(body).to include(label(:processing))
      expect(body).not_to include(label(:waiting_ai))
    end

    # Key-scoped, never blanket: a stub without `with` answers for every key and
    # would keep this file green if the partial asked :chat, :semantic_search or any
    # other row. Both examples pin that it is :content_indexing specifically.
    def stub_feature(key, available)
      allow_any_instance_of(Organisation).to receive(:ai_available_for?).and_call_original
      allow_any_instance_of(Organisation).to receive(:ai_available_for?).with(key).and_return(
        Lalabase::Llm::FeatureRegistry::Availability.new(available: available, reason: (:no_credential unless available))
      )
    end

    it 'reads :content_indexing — refusing it alone flips the badge' do
      organisation.update!(ai_enabled: true, embedding_access_token: 'sk-org-own-embed-1234567890')
      stub_feature(:content_indexing, false)

      expect(badge_for(released)).to include(label(:waiting_ai))
    end

    it 'ignores a NEIGHBOURING key being refused' do
      organisation.update!(ai_enabled: true, embedding_access_token: 'sk-org-own-embed-1234567890')
      stub_feature(:semantic_search, false)

      expect(badge_for(released)).to include(label(:processing))
    end

    # The two examples above are the DIAGONAL of {chat configured} × {embedding
    # configured} — the pair that proves which lane decides. The two remaining
    # corners are what proves the answer is the embedding lane ALONE and not, say,
    # "either lane will do": with both configured the badge must still prepare, with
    # neither it must still wait. The old expression answered three of these four
    # cells the same way, which is why the misparing survived so long.
    {
      'BOTH lanes configured' => { ai_access_token: 'sk-org-own-1234567890abcdef',
                                   embedding_access_token: 'sk-org-own-embed-1234567890',
                                   expected: :processing },
      'NEITHER lane configured' => { ai_access_token: nil, embedding_access_token: nil,
                                     expected: :waiting_ai }
    }.each do |label_text, setup|
      it "shows #{setup[:expected]} with #{label_text}" do
        allow(AiCredential).to receive(:active_for_provider).and_return(nil)
        organisation.update!(ai_enabled: true, ai_provider: 'openai',
                             ai_access_token: setup[:ai_access_token],
                             embedding_access_token: setup[:embedding_access_token])

        expect(badge_for(released)).to include(label(setup[:expected]))
      end
    end

    # The third axis of the state space, and the only render path on which it is
    # reachable: _meeting_show gates the whole partial on ai_enabled?, but
    # MeetingsController#search_status_stream renders it DIRECTLY into a turbo
    # stream, and toggle_search carries no opt-in gate. So an org with AI switched
    # off does reach this partial — where :content_indexing answers :ai_disabled,
    # and the badge has to say "waiting", not "preparing" (nothing will ever index
    # it) and not raise on the nil-safe chain.
    it 'waits, rather than preparing, when the org has no AI opt-in at all' do
      organisation.update!(ai_enabled: false)
      released.update!(create_embeddings: false)
      sign_in writer

      post toggle_path(released), params: { create_embeddings: '1' }, headers: turbo_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(label(:waiting_ai))
      expect(response.body).not_to include(label(:processing))
    end
  end
end
