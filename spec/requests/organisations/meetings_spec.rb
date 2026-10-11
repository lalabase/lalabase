# frozen_string_literal: true

require 'rails_helper'

# MeetingsController request specs — positive AND negative area access, plus
# cross-project isolation. Denial in this app surfaces as an HTTP redirect (the
# ProjectController area gate) or a 404 (record scoped out of @project.meetings),
# NOT a literal 403 — the established convention (see
# project_repositories_documentation_access_spec).
RSpec.describe 'Organisations::Meetings', type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  # Builds a signed-up user whose meetings access on `project` is `level`
  # ('read_only' / 'read_write'), or :none for no access at all.
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

  describe 'GET index' do
    it 'renders for a user with meetings read access' do
      sign_in reader
      get organisation_project_meetings_path(organisation, project)
      expect(response).to have_http_status(:ok)
    end

    it 'ignores the new-meeting page state for a read-only user' do
      sign_in reader
      get organisation_project_meetings_path(organisation, project, new: 'meeting')

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('meeting-form-card')
    end

    it 'redirects a user without meetings access' do
      sign_in no_access_user
      get organisation_project_meetings_path(organisation, project)
      expect(response).to have_http_status(:redirect)
    end

    it 'redirects an unauthenticated user to login' do
      get organisation_project_meetings_path(organisation, project)
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe 'GET show (detail Turbo frame)' do
    let(:meeting) do
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation, creator: writer, title: 'Retro', notes: 'summary')
      end
    end

    it 'renders the meeting detail wrapped in the display turbo-frame for frame=content' do
      sign_in reader
      get organisation_project_meeting_path(organisation, project, meeting, frame: 'content', frame_id: 'meeting_display_frame'),
          headers: { 'Turbo-Frame' => 'meeting_display_frame' }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('turbo-frame', 'meeting_display_frame', 'Retro')
    end

    it 'subscribes to private legacy analysis updates only while this user has a pending run' do
      sign_in writer
      path = organisation_project_meeting_path(organisation, project, meeting, frame: 'content')
      headers = { 'Turbo-Frame' => 'meeting_display_frame' }
      get path, headers: headers
      settled_stream_count = response.body.scan('<turbo-cable-stream-source').size

      ActsAsTenant.with_tenant(organisation) do
        create(:meeting_analysis, meeting: meeting, creator: writer, creation_flag: true)
      end
      get path, headers: headers

      expect(response.body.scan('<turbo-cable-stream-source').size).to eq(settled_stream_count + 1)
    end

    # The stream is creator-scoped, so only the viewer's OWN pending run is worth a
    # subscription. Someone else's published run in progress never reaches this stream.
    it "does not subscribe for another user's pending published run" do
      sign_in reader
      path = organisation_project_meeting_path(organisation, project, meeting, frame: 'content')
      headers = { 'Turbo-Frame' => 'meeting_display_frame' }
      get path, headers: headers
      settled_stream_count = response.body.scan('<turbo-cable-stream-source').size

      ActsAsTenant.with_tenant(organisation) do
        create(:meeting_analysis, meeting: meeting, creator: writer, creation_flag: true, is_private: false)
      end
      get path, headers: headers

      expect(response.body.scan('<turbo-cable-stream-source').size).to eq(settled_stream_count)
    end

    it 'renders into a caller-provided detail frame for cross-area lanes' do
      sign_in reader
      get organisation_project_meeting_path(organisation, project, meeting, frame: 'content', frame_id: 'ticket_display_frame'),
          headers: { 'Turbo-Frame' => 'ticket_display_frame' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('turbo-frame id="ticket_display_frame"', 'Retro')
    end

    it 'renders the full master-detail page for a bookmarked URL without frame param' do
      sign_in reader
      get organisation_project_meeting_path(organisation, project, meeting)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Retro', 'meetings_results')
    end

    it 'renders the full page (not a bare fragment) when frame=content lacks the Turbo-Frame header' do
      # Direct browser visit of the frame URL: turbo_frame_request? is false, so
      # the standalone branch must answer with the complete master-detail page.
      sign_in reader
      get organisation_project_meeting_path(organisation, project, meeting, frame: 'content')
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('meetings_results')
    end

    it 'renders saved participants as chips in the detail header (live-check regression)' do
      # Live-check follow-up: the participants section only renders when
      # participants exist — this locks in that PERSISTED participants actually
      # show up in the detail view (all render paths share this partial).
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting_participant, meeting: meeting, organisation: organisation, display_name: 'Anna Ananas')
        create(:meeting_participant, meeting: meeting, organisation: organisation, display_name: 'Extern Bert')
      end

      sign_in reader
      get organisation_project_meeting_path(organisation, project, meeting)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Anna Ananas', 'Extern Bert')
      expect(response.body).to include(I18n.t('views.organisations.meetings.show.participants_heading'))
    end
  end

  # Notes + transcript are pasted as Markdown from AI transcript tools. The detail
  # view renders them SAFELY (SafeMarkdown: syntax → HTML, then allowlist sanitise)
  # and hides a leading YAML frontmatter block. Storage stays raw markdown.
  describe 'GET show — Markdown rendering' do
    let(:meeting) do
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation, creator: writer, title: 'MD Meeting',
                         notes: "---\nid: FRONTMATTER_SENTINEL_ZZZ\nparent: p-1\n---\n" \
                                "## Themen\n\n**Guido:** Wir starten.\n\n---\n\nNachtrag.",
                         transcript: "**Anna:** Q3 läuft.\n\n[link](javascript:alert(1)) und ![x](http://t/p.png)")
      end
    end

    before { sign_in reader }

    it 'renders notes markdown as HTML (bold speaker, heading, rule) — not literal syntax' do
      get organisation_project_meeting_path(organisation, project, meeting)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<strong>Guido:</strong>')
      expect(response.body).to include('<h2>Themen</h2>')
      expect(response.body).to include('<hr>')
      # The literal markdown markers for the rendered constructs are gone.
      expect(response.body).not_to include('## Themen')
    end

    it 'renders the transcript markdown as HTML too' do
      get organisation_project_meeting_path(organisation, project, meeting)
      expect(response.body).to include('<strong>Anna:</strong>')
    end

    it 'hides a leading YAML frontmatter block from the body AND the excerpt' do
      get organisation_project_meeting_path(organisation, project, meeting)
      expect(response.body).not_to include('FRONTMATTER_SENTINEL_ZZZ')
    end

    it 'does not emit an executable javascript link or an <img> (allowlist)' do
      get organisation_project_meeting_path(organisation, project, meeting)
      expect(response.body).not_to include('javascript:alert(1)')
      expect(response.body).not_to include('<img')
    end

    it 'does not duplicate the meeting body as a separate Abriss' do
      get organisation_project_meeting_path(organisation, project, meeting)
      body = Capybara.string(response.body)
      expect(body).to have_no_css('#meeting-header p.line-clamp-2')
      expect(body).to have_css('#meeting-header h2', text: 'Themen')
    end

    it 'leaves the stored notes untouched (raw markdown incl. frontmatter survives for the edit field)' do
      get organisation_project_meeting_path(organisation, project, meeting)
      expect(meeting.reload.notes).to include('FRONTMATTER_SENTINEL_ZZZ')
      expect(meeting.notes).to include('## Themen')
    end
  end

  # Nachtrag: Teilnehmer-Kennzeichnung — the detail header must visibly distinguish
  # all THREE chip states. reader holds a ProjectPermission on `project` (→ project
  # member); org_only_user is an org member WITHOUT project access (→ org member); a
  # user_id-less participant is external. The tooltip labels are the load-bearing
  # assertion (the human explanation of the colour); the icons back them up.
  describe 'GET show — participant chip type indicators' do
    let(:meeting) do
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation, creator: writer, title: 'Typed Chips')
      end
    end

    let(:org_only_user) do
      user = create(:user, first_name: 'Olga', last_name: 'Orga')
      ActsAsTenant.with_tenant(organisation) do
        role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
        create(:membership, user: user, organisation: organisation, role: role, active: true)
      end
      user
    end

    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting_participant, meeting: meeting, organisation: organisation, display_name: 'Rita Reader', user: reader)
        create(:meeting_participant, meeting: meeting, organisation: organisation, display_name: 'Olga Orga', user: org_only_user)
        create(:meeting_participant, meeting: meeting, organisation: organisation, display_name: 'Extern Erna')
      end
    end

    it 'tags each participant project-member / org-member / external' do
      sign_in reader
      get organisation_project_meeting_path(organisation, project, meeting)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('views.organisations.meetings.shared.participant_type.project_member'))
      expect(response.body).to include(I18n.t('views.organisations.meetings.shared.participant_type.org_member'))
      expect(response.body).to include(I18n.t('views.organisations.meetings.shared.participant_type.external'))
      # Distinct icons (bare "bi-person" would be ambiguous — it is a prefix of both).
      expect(response.body).to include('bi-person-check', 'bi-person-dash')
    end
  end

  describe 'GET index — content search' do
    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation, creator: writer,
                         title: 'Kickoff Sanierung', notes: 'Dachziegel bestellen bei Meier')
        create(:meeting, project: project, organisation: organisation, creator: writer, title: 'Retro Q3')
      end
    end

    it 'filters the list to matching titles' do
      sign_in reader
      get organisation_project_meetings_path(organisation, project, search: 'Kickoff')
      expect(response.body).to include('Kickoff Sanierung')
      expect(response.body).not_to include('Retro Q3')
    end

    it 'filters on body content (notes/transcript), not just the title' do
      # The word lives only in the notes, never in a title — proves the search
      # reaches plain_text_version, the actual fix (was title-only before).
      sign_in reader
      get organisation_project_meetings_path(organisation, project, search: 'Dachziegel')
      expect(response.body).to include('Kickoff Sanierung')
      expect(response.body).not_to include('Retro Q3')
    end

    it 'tolerates a non-scalar search param (?search[]=x) instead of raising' do
      # Locks in the .to_s guard inside Meeting.search_by_content — dropping it
      # would let sanitize_sql_like raise on an Array param (500).
      sign_in reader
      get organisation_project_meetings_path(organisation, project, params: { search: ['x'] })
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'GET new / GET edit (inline form)' do
    let(:meeting) do
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation, creator: writer, title: 'Editierbar')
      end
    end

    it 'renders the inline form in the detail frame for a writer' do
      sign_in writer
      get new_organisation_project_meeting_path(organisation, project, frame: 'content', frame_id: 'meeting_display_frame'),
          headers: { 'Turbo-Frame' => 'meeting_display_frame' }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('meeting_display_frame', 'meeting-form-card')
    end

    it 'renders the participant field as a <select multiple> (no Contacts-autofill text input)' do
      # Regression guard for the SlimSelect rework: a name-like text input gets
      # Safari's macOS Contacts autofill overlaid regardless of autocomplete= /
      # type=search (both verified ignored on prod); a <select> widget does not.
      # Flip this back to a text input and it fails. See _form_fields.html.erb.
      sign_in writer
      get new_organisation_project_meeting_path(organisation, project, frame: 'content', frame_id: 'meeting_display_frame'),
          headers: { 'Turbo-Frame' => 'meeting_display_frame' }
      expect(response).to have_http_status(:ok)
      rendered = Capybara.string(response.body)
      expect(rendered).to have_css('select#meeting-participants-select[multiple]', visible: :all)
      expect(rendered).to have_no_css('input#meeting-participants-input')
      # Members are server-rendered as "user:<uuid>" options (the picker source).
      expect(rendered).to have_css(%(select#meeting-participants-select option[value="user:#{writer.id}"]), visible: :all)
    end

    it 'redirects a reader away from new (no write access)' do
      sign_in reader
      get new_organisation_project_meeting_path(organisation, project, frame: 'content')
      expect(response).to have_http_status(:redirect)
    end

    it 'streams the edit form into the detail frame for a writer' do
      sign_in writer
      get edit_organisation_project_meeting_path(organisation, project, meeting, format: :turbo_stream)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('meeting_display_frame', 'meeting-form-card')
    end

    it 'redirects a reader away from edit (no write access)' do
      sign_in reader
      get edit_organisation_project_meeting_path(organisation, project, meeting)
      expect(response).to have_http_status(:redirect)
    end
  end

  describe 'POST create' do
    let(:valid_params) { { meeting: { title: 'Kickoff', occurred_at: Time.current, notes: 'agenda' } } }

    it 'creates a meeting for a writer' do
      sign_in writer
      expect do
        post organisation_project_meetings_path(organisation, project), params: valid_params
      end.to change { ActsAsTenant.with_tenant(organisation) { project.meetings.count } }.by(1)
    end

    it 'preserves list filters and viewport in the HTML redirect' do
      sign_in writer
      post organisation_project_meetings_path(organisation, project),
           params: valid_params.merge(search: 'Kick', participant: 'anna', viewport: 'mobile')

      meeting = ActsAsTenant.with_tenant(organisation) { project.meetings.find_by!(title: 'Kickoff') }
      expect(response).to redirect_to(
        organisation_project_meetings_path(
          organisation,
          project,
          search: 'Kick', participant: 'anna', viewport: 'mobile', meeting_id: meeting.id
        )
      )
    end

    it 'returns a turbo_stream refreshing the list and detail (the real inline-form flow)' do
      sign_in writer
      post organisation_project_meetings_path(organisation, project),
           params: valid_params.merge(search: 'Kick', participant: writer.id, viewport: 'desktop'),
           as: :turbo_stream
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(response.body).to include('meetings_results') # list frame refreshed with the new row
      expect(response.body).to include('meeting_display_frame') # detail pane shows the new meeting
      expect(response.body).to include('Kickoff')
      address_stream = Nokogiri::HTML.fragment(response.body).at_css('turbo-stream[action="replaceAddress"]')
      expect(address_stream['url']).to include(
        'meeting_id=',
        'search=Kick',
        "participant=#{writer.id}",
        'viewport=desktop'
      )
      streams = Nokogiri::HTML.fragment(response.body).css('turbo-stream')
      address_index = streams.index { |stream| stream['action'] == 'replaceAddress' }
      list_index = streams.index { |stream| stream['target'] == 'meetings_results' }
      expect(address_index).to be < list_index
    end

    it 'returns 422 and re-renders the inline form on an invalid submit' do
      sign_in writer
      post organisation_project_meetings_path(organisation, project),
           params: {
             meeting: { title: '', occurred_at: Time.current },
             search: 'alpha', participant: 'anna', viewport: 'desktop'
           }, as: :turbo_stream
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('meeting-form-card') # the form partial, re-rendered with errors
      expect(response.body).to include('search=alpha', 'participant=anna', 'viewport=desktop')
      expect { ActsAsTenant.with_tenant(organisation) { Meeting.find_by(title: '') } }.not_to raise_error
    end

    it 'denies create for a reader (no write) and creates nothing' do
      sign_in reader
      expect do
        post organisation_project_meetings_path(organisation, project), params: valid_params
      end.not_to(change { ActsAsTenant.with_tenant(organisation) { Meeting.count } })
      expect(response).to have_http_status(:redirect)
    end

    it 'denies create for a no-access user' do
      sign_in no_access_user
      expect do
        post organisation_project_meetings_path(organisation, project), params: valid_params
      end.not_to(change { ActsAsTenant.with_tenant(organisation) { Meeting.count } })
    end
  end

  describe 'PATCH update' do
    let(:meeting) do
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation, creator: writer, title: 'Before')
      end
    end

    it 'updates the meeting and streams the refreshed detail for a writer' do
      sign_in writer
      patch organisation_project_meeting_path(organisation, project, meeting),
            params: { meeting: { title: 'After' } }, as: :turbo_stream
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(response.body).to include('After')
      expect(ActsAsTenant.with_tenant(organisation) { meeting.reload.title }).to eq('After')
    end

    it 'denies update for a reader (no write) and changes nothing' do
      sign_in reader
      patch organisation_project_meeting_path(organisation, project, meeting),
            params: { meeting: { title: 'Hacked' } }, as: :turbo_stream
      expect(response).to have_http_status(:redirect)
      expect(ActsAsTenant.with_tenant(organisation) { meeting.reload.title }).to eq('Before')
    end

    it 'redirects with a friendly alert when the meeting vanished mid-update (delete race)' do
      # Simulates the meeting being deleted between set_meeting and the actor's
      # own lookup — the actor then has no record; rendering the form with a nil
      # meeting used to 500.
      sign_in writer
      actor = instance_double(Actors::SaveMeeting, call: double('result', success?: false), record: nil)
      allow(Actors::SaveMeeting).to receive(:new).and_return(actor)

      patch organisation_project_meeting_path(organisation, project, meeting),
            params: { meeting: { title: 'After' } }, as: :turbo_stream
      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(I18n.t('flash.meetings.not_found'))
    end
  end

  describe 'DELETE destroy' do
    let!(:meeting) do
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation, creator: writer)
      end
    end

    it 'destroys the meeting and streams the list + placeholder for a writer' do
      sign_in writer
      expect do
        delete organisation_project_meeting_path(organisation, project, meeting), as: :turbo_stream
      end.to change { ActsAsTenant.with_tenant(organisation) { Meeting.count } }.by(-1)
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(response.body).to include('meetings_results')
    end

    it 'denies destroy for a reader (no write) and deletes nothing' do
      sign_in reader
      expect do
        delete organisation_project_meeting_path(organisation, project, meeting), as: :turbo_stream
      end.not_to(change { ActsAsTenant.with_tenant(organisation) { Meeting.count } })
    end

    it 'redirects with a generic alert on an unexpected destroy error — never the exception message' do
      # The rescue path must log internals but keep them out of the user flash
      # (constraint names / model state are information disclosure).
      sign_in writer
      allow_any_instance_of(Meeting).to receive(:destroy).and_raise(StandardError, 'PG::ForeignKeyViolation secret_internal_detail')

      delete organisation_project_meeting_path(organisation, project, meeting)
      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(I18n.t('flash.meetings.delete_error'))
      expect(flash[:alert]).not_to include('secret_internal_detail')
    end
  end

  describe 'cross-project isolation' do
    let(:project_b) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
    let(:meeting_b) do
      ActsAsTenant.with_tenant(organisation) { create(:meeting, project: project_b, organisation: organisation, creator: writer) }
    end

    it 'returns 404 when a meeting is requested through a different project URL' do
      # reader can read meetings in BOTH projects, so the area gate on `project`
      # passes — but the meeting lives in project_b and is looked up under
      # `project`, so it is not found.
      ActsAsTenant.with_tenant(organisation) do
        create(:project_permission, user: reader, project: project_b, meetings_access: 'read_only')
      end
      sign_in reader
      get organisation_project_meeting_path(organisation, project, meeting_b)
      expect(response).to have_http_status(:not_found)
    end
  end

  # Picker options are now server-rendered into the form's <select> (the
  # participant_suggestions JSON endpoint was removed). These guard the same
  # security property the endpoint spec did — the leak guard (plan §7) — at the new
  # surface. Only writers reach the form, so the viewing user is a writer on
  # `project` who cannot read project_b.
  describe 'participant options in the meeting form' do
    def form_body(user)
      sign_in user
      get new_organisation_project_meeting_path(organisation, project, frame: 'content', frame_id: 'meeting_display_frame'),
          headers: { 'Turbo-Frame' => 'meeting_display_frame' }
      Capybara.string(response.body)
    end

    it 'renders project members and external names from readable projects as options' do
      ActsAsTenant.with_tenant(organisation) do
        meeting = create(:meeting, project: project, organisation: organisation, creator: writer)
        create(:meeting_participant, meeting: meeting, display_name: 'Extern Anna')
      end

      rendered = form_body(writer)
      expect(rendered).to have_css(%(select#meeting-participants-select option[value="user:#{writer.id}"]), visible: :all)
      expect(rendered).to have_css('select#meeting-participants-select option', text: 'Extern Anna', visible: :all)
    end

    # Regression (member source): options were sourced from @project.permitted_users,
    # which is ONLY direct ProjectPermission rows — so a member who reaches the project
    # via org-admin or a global role (e.g. the org owner) was NEVER suggested. The
    # canonical source is @project.users_with_access(:read, :meetings), the same one the
    # ticket-assignee picker uses (TicketsHelper#assignable_users_for).
    it 'suggests an org-admin who has access without a direct project_permission' do
      admin = create(:user, first_name: 'Ada', last_name: 'Adminsson')
      ActsAsTenant.with_tenant(organisation) { setup_admin_role(admin, organisation) }

      rendered = form_body(writer)
      expect(rendered).to have_css(%(select#meeting-participants-select option[value="user:#{admin.id}"]), visible: :all)
    end

    # The core leak guard (plan §7): an external name from a project the user
    # cannot read in the :meetings area must never appear as an option.
    it 'does not leak external names from a project the user cannot read' do
      project_b = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      ActsAsTenant.with_tenant(organisation) do
        meeting_b = create(:meeting, project: project_b, organisation: organisation, creator: writer)
        create(:meeting_participant, meeting: meeting_b, display_name: 'Geheim Bert')
      end

      rendered = form_body(writer) # read_write on `project`, no access to project_b
      expect(rendered).to have_no_css('option', text: 'Geheim Bert', visible: :all)
    end
  end

  # AI summary (Slice 4). Covers the write-authorization gate, the D3 gate trio
  # (invisible / disabled+hint / active), and the D9 source rule at the request
  # boundary (blank content → no enqueue). The actual LLM text/source selection is
  # asserted in the service unit spec; here the job is stubbed at perform_later.
  describe 'POST create_summary' do
    let(:meeting) do
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation, creator: writer,
                         title: 'Kickoff', transcript: 'Kunde will Feature X bis Q3.')
      end
    end

    def create_summary_path
      create_summary_organisation_project_meeting_path(organisation, project, meeting)
    end

    def show_content(user)
      sign_in user
      get organisation_project_meeting_path(organisation, project, meeting, frame: 'content'),
          headers: { 'Turbo-Frame' => 'meeting_display_frame' }
    end

    context 'write authorization' do
      before { allow_any_instance_of(Organisation).to receive(:has_valid_ai_configuration?).and_return(true) }

      it 'enqueues the summary job for a writer and redirects with a notice' do
        sign_in writer
        expect(Meetings::SummaryJob).to receive(:perform_later).with(meeting_id: meeting.id)
        post create_summary_path
        expect(response).to have_http_status(:redirect)
        expect(meeting.reload.summary_creation_flag).to be(true)
      end

      it 'denies a read-only user (redirect) and does not enqueue' do
        sign_in reader
        expect(Meetings::SummaryJob).not_to receive(:perform_later)
        post create_summary_path
        expect(response).to have_http_status(:redirect)
        expect(meeting.reload.summary_creation_flag).to be(false)
      end

      it 'denies a user without meetings access and does not enqueue' do
        sign_in no_access_user
        expect(Meetings::SummaryJob).not_to receive(:perform_later)
        post create_summary_path
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'gate trio (plan D3)' do
      context 'AI available (opt-in + configured)' do
        before { allow_any_instance_of(Organisation).to receive(:has_valid_ai_configuration?).and_return(true) }

        it 'shows the active generate button' do
          show_content(writer)
          expect(response.body).to include(I18n.t('views.organisations.meetings.show.generate_summary'))
        end

        # The label alone cannot discriminate active from disabled (both render it) —
        # only the enabled button carries the submit form. Kills the mutant that
        # hardcodes summary_disabled = true (review #235).
        it 'renders the enabled submit form for the summary' do
          show_content(writer)
          expect(response.body).to include(create_summary_organisation_project_meeting_path(organisation, project, meeting))
        end

        it 'enqueues on POST' do
          sign_in writer
          expect(Meetings::SummaryJob).to receive(:perform_later)
          post create_summary_path
        end
      end

      context 'opt-in but NOT configured' do
        before { allow_any_instance_of(Organisation).to receive(:has_valid_ai_configuration?).and_return(false) }

        it 'shows the setup hint instead of an active button' do
          show_content(writer)
          expect(response.body).to include(I18n.t('views.organisations.meetings.show.summary_setup_hint'))
        end

        it 'does not render a submit form for the summary' do
          show_content(writer)
          expect(response.body).not_to include(create_summary_organisation_project_meeting_path(organisation, project, meeting))
        end

        it 'does not enqueue on POST and hints at the AI config' do
          sign_in writer
          expect(Meetings::SummaryJob).not_to receive(:perform_later)
          post create_summary_path
          expect(response).to have_http_status(:redirect)
        end
      end

      context 'opt-out (feature invisible)' do
        let(:organisation) { create(:organisation, :ai_disabled) }

        it 'renders neither the generate button nor the setup hint' do
          show_content(writer)
          expect(response.body).not_to include(I18n.t('views.organisations.meetings.show.generate_summary'))
          expect(response.body).not_to include(I18n.t('views.organisations.meetings.show.summary_setup_hint'))
        end

        it 'does not enqueue on POST' do
          sign_in writer
          expect(Meetings::SummaryJob).not_to receive(:perform_later)
          post create_summary_path
        end
      end

      # R2 (doc/ai_feature_registry_plan.md §6): the meeting page carries THREE AI
      # surfaces and they ask THREE different registry rows — not one shared "can this
      # org chat" question, which is what they all asked before this slice.
      #
      # Inherited from the E5 delegation example in organisation_ai_availability_spec:
      # that one asserted the registry's answer wins over the low-level predicates, and
      # the facade it asserted it on is gone. Same stubbing technique, aimed at real
      # call sites instead.
      #
      # Why it needs its own example: every unpinned chat feature answers identically
      # today, so a mis-keyed call site is invisible in production AND to every other
      # example in this file. Failing exactly ONE row is what makes the keys visible —
      # and the day the packages domain lets features diverge, this is the guard that
      # was already in place.
      context 'feature keys (R2)' do
        before do
          allow_any_instance_of(Organisation).to receive(:has_valid_ai_configuration?).and_return(true)
          allow(ChatPolicy).to receive(:assistant_gate_open?).and_return(true)
        end

        def refuse_only(feature_key)
          allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).and_call_original
          allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).with(feature_key, anything).and_return(
            Lalabase::Llm::FeatureRegistry::Availability.new(available: false, reason: :no_credential)
          )
        end

        it 'takes down only the surface whose own key says no' do
          refuse_only(:meeting_summary)

          show_content(writer)

          expect(response.body).not_to include(create_summary_path)
          expect(response.body).to include(I18n.t('views.organisations.meetings.show.summary_setup_hint'))
          # A different row, untouched by the stub: the ticket-suggestions entry on
          # the same render still opens the assistant in its explicit mode. Without
          # this half, a summary section keyed to any old feature would pass.
          expect(response.body).to include('data-assistant-trigger-intent-value="ticket-suggestions"')
        end

        it 'refuses the POST on the summary key too — gate and action read one row' do
          refuse_only(:meeting_summary)
          sign_in writer

          expect(Meetings::SummaryJob).not_to receive(:perform_later)
          post create_summary_path

          expect(flash[:alert]).to eq(I18n.t('flash.meetings.summary_ai_unavailable'))
        end

        # The other direction: refusing a FOREIGN row must leave the summary alone.
        # Without it, a controller that still asked a generic chat question would
        # pass the example above (its key is stubbed) and fail nothing.
        it 'leaves the summary alone when a foreign row says no' do
          refuse_only(:meeting_ticket_suggestions)
          sign_in writer

          expect(Meetings::SummaryJob).to receive(:perform_later).with(meeting_id: meeting.id)
          post create_summary_path
        end
      end
    end

    # Idempotency guard (review #235): a running generation blocks re-enqueue; a
    # STALE flag (lost job, worker outage) does not — the guard self-heals after
    # Meeting::SUMMARY_STALE_AFTER so the feature can never be bricked.
    context 'while a generation is already running' do
      before do
        allow_any_instance_of(Organisation).to receive(:has_valid_ai_configuration?).and_return(true)
        ActsAsTenant.with_tenant(organisation) { meeting.update!(summary_creation_flag: true) }
      end

      it 'does not enqueue a second job and hints (fresh flag)' do
        sign_in writer
        expect(Meetings::SummaryJob).not_to receive(:perform_later)
        post create_summary_path
        expect(response).to have_http_status(:redirect)
        expect(flash[:alert]).to eq(I18n.t('flash.meetings.summary_already_running'))
      end

      it 're-enqueues when the pending flag is stale (self-healing)' do
        # backdating updated_at NEEDS to bypass touch
        ActsAsTenant.with_tenant(organisation) do
          meeting.update_column(:updated_at, (Meeting::SUMMARY_STALE_AFTER + 1.minute).ago)
        end
        sign_in writer
        expect(Meetings::SummaryJob).to receive(:perform_later).with(meeting_id: meeting.id)
        post create_summary_path
        expect(response).to have_http_status(:redirect)
      end
    end

    # Locks the summary-present rendering at request level: Abriss prefers the
    # summary over the notes, and the button switches to the regenerate label
    # (review #235 — this state was previously only rendered in unit specs).
    context 'with an existing summary' do
      before do
        allow_any_instance_of(Organisation).to receive(:has_valid_ai_configuration?).and_return(true)
        ActsAsTenant.with_tenant(organisation) do
          # One save setting summary AND notes together also pins the invalidation
          # exception: an explicit generated_summary write survives a source change.
          meeting.update!(generated_summary: 'KI-KURZFASSUNG-XYZ', notes: 'ROHNOTIZEN-ABC')
        end
      end

      it 'shows the summary text and the regenerate button' do
        show_content(writer)
        expect(response.body).to include('KI-KURZFASSUNG-XYZ')
        expect(response.body).to include(I18n.t('views.organisations.meetings.show.regenerate_summary'))
      end
    end

    context 'source rule (plan D9): both content fields blank' do
      let(:meeting) do
        ActsAsTenant.with_tenant(organisation) do
          create(:meeting, project: project, organisation: organisation, creator: writer,
                           title: 'Pure time anchor', notes: nil, transcript: nil)
        end
      end

      before { allow_any_instance_of(Organisation).to receive(:has_valid_ai_configuration?).and_return(true) }

      it 'does not enqueue and leaves the flag unset' do
        sign_in writer
        expect(Meetings::SummaryJob).not_to receive(:perform_later)
        post create_summary_path
        expect(meeting.reload.summary_creation_flag).to be(false)
      end
    end

    # The real button submits via Turbo. These exercise the turbo_stream response
    # branches (summary section replace / flash hint) so a rendering regression
    # surfaces as a failing spec, not a 500 in the browser.
    context 'turbo_stream responses (the real button path)' do
      it 'renders the summary section in progress on success' do
        allow_any_instance_of(Organisation).to receive(:has_valid_ai_configuration?).and_return(true)
        allow(Meetings::SummaryJob).to receive(:perform_later)
        sign_in writer
        post create_summary_path, as: :turbo_stream
        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq('text/vnd.turbo-stream.html')
        expect(response.body).to include(I18n.t('views.organisations.meetings.show.summary_in_progress'))
      end

      it 'renders a hint (422) without enqueue when content is blank' do
        allow_any_instance_of(Organisation).to receive(:has_valid_ai_configuration?).and_return(true)
        blank = ActsAsTenant.with_tenant(organisation) do
          create(:meeting, project: project, organisation: organisation, creator: writer, notes: nil, transcript: nil)
        end
        sign_in writer
        expect(Meetings::SummaryJob).not_to receive(:perform_later)
        post create_summary_organisation_project_meeting_path(organisation, project, blank), as: :turbo_stream
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('flash.meetings.summary_no_content'))
      end
    end

    # S1c (doc/ki_provider_reichweite_plan.md §2.1b) at the request boundary, with
    # the gate NOT stubbed — every context above stubs has_valid_ai_configuration?
    # and would therefore not notice which provider the gate asked about.
    #
    # Google/Vertex is LIVE in production (europe-west3/-west1, gemini-2.5-flash,
    # active system credential of type google), so real orgs carry
    # ai_provider = 'google'. For them S1c is a behaviour change, not a no-op:
    # the views used to ask ai_available?('openai'), i.e. "does SOME OpenAI
    # credential exist" — the buttons of a Vertex org hung on a foreign credential.
    describe 'the AI gate follows the org provider (S1c)' do
      def summary_button_rendered?
        # The active button carries the POST form action; when disabled the
        # component renders no form, so the path is absent from the body.
        response.body.include?(create_summary_path)
      end

      context 'with a google org on the live production setup (active google credential)' do
        let(:organisation) { create(:organisation, ai_enabled: true, ai_provider: 'google') }

        before { create(:ai_credential, :google, :active) }

        it 'still renders the active summary button — this must not kip over on deploy' do
          show_content(writer)

          expect(response).to have_http_status(:ok)
          expect(summary_button_rendered?).to be(true)
          expect(response.body).not_to include(I18n.t('views.organisations.meetings.show.summary_setup_hint'))
        end

        it 'still accepts the POST and enqueues the job' do
          sign_in writer
          expect(Meetings::SummaryJob).to receive(:perform_later).with(meeting_id: meeting.id)
          post create_summary_path
          expect(meeting.reload.summary_creation_flag).to be(true)
        end
      end

      # THE INTENDED CORRECTION, NOT A REGRESSION. Before S1c this org saw the
      # button (an unrelated OpenAI credential existed) and the click failed in the
      # job with Factory::MissingCredentialError for provider "google". The button
      # is now withheld instead — "feature missing" rather than "feature lies".
      context 'with a google org whose google credential is NOT active (only openai is)' do
        let(:organisation) { create(:organisation, ai_enabled: true, ai_provider: 'google') }

        before { create(:ai_credential, :active, provider: 'openai') }

        it 'withholds the button and shows the setup hint instead' do
          show_content(writer)

          expect(response).to have_http_status(:ok)
          expect(summary_button_rendered?).to be(false)
          expect(response.body).to include(I18n.t('views.organisations.meetings.show.summary_setup_hint'))
        end

        it 'refuses the crafted POST instead of enqueueing a job that cannot succeed' do
          sign_in writer
          expect(Meetings::SummaryJob).not_to receive(:perform_later)
          post create_summary_path
          expect(flash[:alert]).to eq(I18n.t('flash.meetings.summary_ai_unavailable'))
          expect(meeting.reload.summary_creation_flag).to be(false)
        end
      end
    end
  end

  describe 'search & chat opt-in (Slice 6)' do
    before { allow(EmbeddingProcessingJob).to receive(:perform_later) }

    it 'persists create_embeddings from the form on update' do
      meeting = ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation, creator: writer, notes: 'Inhalt')
      end
      sign_in writer
      patch organisation_project_meeting_path(organisation, project, meeting),
            params: { meeting: { title: meeting.title, occurred_at: meeting.occurred_at, notes: 'Inhalt', create_embeddings: '1' } },
            as: :turbo_stream
      expect(response).to have_http_status(:ok)
      expect(meeting.reload.create_embeddings).to be(true)
    end

    # Behavioral half of the disabled-toggle contract (review PR #247): the form
    # comment claims a disabled checkbox sends NO param (Rails disables the hidden
    # partner field too) and thus never silently flips the stored value. Reachable
    # state: content cleared while the opt-in stays true → the next edit renders a
    # disabled checkbox over a stored true. A submit omitting the key must keep it.
    it 'a submit omitting create_embeddings does NOT flip a stored true (disabled-toggle contract)' do
      meeting = ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation, creator: writer,
                         notes: 'Inhalt', create_embeddings: true)
      end
      ActsAsTenant.with_tenant(organisation) do
        meeting.update!(notes: nil, transcript: nil)
      end

      sign_in writer
      patch organisation_project_meeting_path(organisation, project, meeting),
            params: { meeting: { title: meeting.title, occurred_at: meeting.occurred_at } },
            as: :turbo_stream

      expect(response).to have_http_status(:ok)
      expect(meeting.reload.create_embeddings).to be(true)
    end

    it 'shows the opt-in toggle DISABLED while the meeting has no indexable content (plan A3)' do
      empty = ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation, creator: writer, notes: nil, transcript: nil)
      end
      sign_in writer
      get edit_organisation_project_meeting_path(organisation, project, empty), as: :turbo_stream
      checkbox = Nokogiri::HTML(response.body).at_css('input#meeting_create_embeddings')
      expect(checkbox).to be_present
      expect(checkbox[:disabled]).to be_present
    end

    it 'enables the opt-in toggle once the meeting has indexable content' do
      filled = ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation, creator: writer, notes: 'Etwas Inhalt')
      end
      sign_in writer
      get edit_organisation_project_meeting_path(organisation, project, filled), as: :turbo_stream
      checkbox = Nokogiri::HTML(response.body).at_css('input#meeting_create_embeddings')
      expect(checkbox).to be_present
      expect(checkbox[:disabled]).to be_nil
    end
  end
end
