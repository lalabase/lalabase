# frozen_string_literal: true

require 'rails_helper'

# Org-wide meetings index (Gespräche Slice 1c): "all conversations with person X"
# across project boundaries. The load-bearing guarantee is SCOPING — the list,
# both filters AND the filter options must never reveal a meeting (or a
# participant name) from a project the current user cannot read in the :meetings
# area, and never from another organisation. Denial for a user with no meetings
# access anywhere surfaces as a redirect (the app convention — not a literal 403).
RSpec.describe 'Organisations::MeetingsOverview', type: :request do
  let(:organisation) { create(:organisation) }
  let(:project_a) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Alpha') } }
  let(:project_b) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Beta') } }

  # A signed-up user whose meetings access is granted per project via
  # ProjectPermission. `on:` accepts a single project or an array; :none grants
  # membership but no project access at all.
  def user_with_access(level, on: project_a)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      Array(on).each { |proj| create(:project_permission, user: user, project: proj, meetings_access: level) } unless level == :none
    end
    user
  end

  let(:overview_path) { organisation_meetings_path(organisation) }

  # reader_a can read meetings only in project_a.
  let(:reader_a) { user_with_access('read_only', on: project_a) }
  let(:no_access_user) { user_with_access(:none) }

  def create_meeting(project:, title:, participants: [], occurred_at: Time.current)
    ActsAsTenant.with_tenant(organisation) do
      meeting = create(:meeting, project: project, organisation: organisation, creator: reader_a, title: title, occurred_at: occurred_at)
      participants.each { |name| create(:meeting_participant, meeting: meeting, display_name: name) }
      meeting
    end
  end

  describe 'access gate' do
    it 'renders for a user with meetings read access in at least one project' do
      sign_in reader_a
      get overview_path
      expect(response).to have_http_status(:ok)
    end

    it 'redirects a user with no meetings access in any project' do
      sign_in no_access_user
      get overview_path
      expect(response).to have_http_status(:redirect)
    end

    it 'redirects an unauthenticated user to login' do
      get overview_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe 'project scoping (the load-bearing negative path)' do
    let!(:meeting_a) { create_meeting(project: project_a, title: 'Alpha Kickoff', participants: ['Anna Müller']) }
    let!(:meeting_b) { create_meeting(project: project_b, title: 'Beta Retro', participants: ['Bert Berg']) }

    before { sign_in reader_a } # read access on project_a only

    it 'shows meetings from the readable project and hides those from the unreadable one' do
      get overview_path
      expect(response.body).to include('Alpha Kickoff')
      expect(response.body).not_to include('Beta Retro')
    end

    it 'shows the readable project name but never the unreadable one' do
      get overview_path
      expect(response.body).to include('Projekt Alpha')
      expect(response.body).not_to include('Projekt Beta')
    end

    it 'does not leak the unreadable project\'s participant into the filter options' do
      get overview_path
      # Bind the actual <select> option, not the table cell: assert the participant
      # dropdown renders and lists the readable participant by its normalized value
      # (which only surfaces in an <option>), and never the unreadable project's name.
      expect(response.body).to include('name="participant"')
      expect(response.body).to include(%(value="#{MeetingParticipant.normalize_name('Anna Müller')}"))
      expect(response.body).not_to include('Bert Berg')
    end

    it 'does not let a participant filter reach into an unreadable project (no bypass)' do
      # Filter by project_b's participant: even though such a meeting exists, the
      # user cannot read it, so nothing matches — no leak through the filter.
      get overview_path, params: { participant: MeetingParticipant.normalize_name('Bert Berg') }
      expect(response.body).not_to include('Beta Retro')
      expect(response.body).not_to include('Alpha Kickoff') # the filter also excludes non-matching readable meetings
    end

    it 'does not let a forged project_id filter reach into an unreadable project (no bypass)' do
      get overview_path, params: { project_id: project_b.id }
      expect(response.body).not_to include('Beta Retro')
    end
  end

  describe 'cross-tenant isolation' do
    let(:other_org) { create(:organisation) }
    let(:other_project) { ActsAsTenant.with_tenant(other_org) { create(:project, organisation: other_org, name: 'Fremd Projekt') } }

    before do
      ActsAsTenant.with_tenant(other_org) do
        other_creator = create(:user)
        create(:meeting, project: other_project, organisation: other_org, creator: other_creator, title: 'Fremd Meeting')
      end
    end

    it 'never shows meetings from another organisation' do
      create_meeting(project: project_a, title: 'Alpha Kickoff')
      sign_in reader_a
      get overview_path
      expect(response.body).to include('Alpha Kickoff')
      expect(response.body).not_to include('Fremd Meeting')
    end
  end

  describe 'participant filter (normalized-name equivalence)' do
    before { sign_in reader_a }

    it 'matches across umlaut spellings (Müller filter finds a Mueller participant)' do
      # Participant stored with the transliterated spelling; filtering with the
      # umlaut spelling must still match (both normalize to "anna mueller").
      create_meeting(project: project_a, title: 'Alpha Kickoff', participants: ['Anna Mueller'])
      create_meeting(project: project_a, title: 'Alpha Sync', participants: ['Clara Klein'])

      get overview_path, params: { participant: MeetingParticipant.normalize_name('Anna Müller') }
      expect(response.body).to include('Alpha Kickoff')
      expect(response.body).not_to include('Alpha Sync')
    end

    it 'combines the participant filter with the title search' do
      create_meeting(project: project_a, title: 'Alpha Kickoff', participants: ['Anna Mueller'])
      create_meeting(project: project_a, title: 'Beta Kickoff wording', participants: ['Anna Mueller'])

      get overview_path, params: { participant: MeetingParticipant.normalize_name('Anna Mueller'), search: 'Alpha' }
      expect(response.body).to include('Alpha Kickoff')
      expect(response.body).not_to include('Beta Kickoff wording')
    end

    it 'combines the project filter with the participant filter' do
      create_meeting(project: project_a, title: 'Alpha Kickoff', participants: ['Anna Mueller'])
      # reader has access to project_a only; passing its id must keep working.
      get overview_path, params: { project_id: project_a.id, participant: MeetingParticipant.normalize_name('Anna Mueller') }
      expect(response.body).to include('Alpha Kickoff')
    end
  end

  describe 'project filter options scoping' do
    # The project <select> renders only with 2+ readable projects; a third same-org
    # project the user cannot read must never appear as an option (the OPTIONS
    # channel the guarantee names). Regressing project_filter_options to
    # Project.all / organisation.projects would leak "Projekt Gamma" and fail here.
    let(:reader_ab) { user_with_access('read_only', on: [project_a, project_b]) }
    let!(:project_c) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Gamma') } }

    it 'lists only readable projects in the dropdown, never an unreadable one' do
      create_meeting(project: project_a, title: 'Alpha Kickoff') # give the page a row
      sign_in reader_ab
      get overview_path
      expect(response.body).to include('name="project_id"') # dropdown rendered
      # "Projekt Beta" has no meeting row, so its only surface is the option list.
      expect(response.body).to include('Projekt Alpha', 'Projekt Beta')
      expect(response.body).not_to include('Projekt Gamma') # unreadable → never an option
    end
  end

  describe 'navigation entry visibility (can_view_meetings gate)' do
    # Same user, same sidebar page, ONLY meetings access toggled — isolates
    # can_view_meetings from the outer nav gate (the user always passes it via
    # tickets read) and from the page. The tickets index renders the org sidebar.
    let(:tickets_permission) do
      user = create(:user)
      permission = nil
      ActsAsTenant.with_tenant(organisation) do
        role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
        create(:membership, user: user, organisation: organisation, role: role, active: true)
        permission = create(:project_permission, user: user, project: project_a, tickets_access: 'read_only')
      end
      permission
    end
    let(:tickets_user) { tickets_permission.user }
    let(:sidebar_path) { organisation_project_tickets_path(organisation, project_a) }

    it 'hides "Alle Gespräche" from a sidebar user without meetings access' do
      sign_in tickets_user
      get sidebar_path
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t('navigation.all_meetings'))
    end

    it 'shows "Alle Gespräche" once the same user gains meetings read access' do
      ActsAsTenant.with_tenant(organisation) { tickets_permission.update!(meetings_access: 'read_only') }
      sign_in tickets_user
      get sidebar_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('navigation.all_meetings'))
    end
  end

  describe 'navigation collapsible group ("Zeiten" / "Alle Meetings")' do
    # The org sidebar hides "Zeiten" + "Alle Meetings" behind a one-way
    # "mehr …" reveal ONLY when BOTH are present (would push the base nav past 4
    # items); a single extra entry stays inline. Reached via the tickets index so
    # the same user renders the sidebar while we toggle time/meetings access
    # independently. On the extra entries' own pages the group renders expanded so
    # the active location never hides behind "mehr …".
    let(:base_permission) do
      user = create(:user)
      permission = nil
      ActsAsTenant.with_tenant(organisation) do
        role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
        create(:membership, user: user, organisation: organisation, role: role, active: true)
        permission = create(:project_permission, user: user, project: project_a, tickets_access: 'read_only')
      end
      permission
    end
    let(:sidebar_user) { base_permission.user }
    let(:sidebar_path) { organisation_project_tickets_path(organisation, project_a) }
    let(:times_path) { organisation_time_sessions_path(organisation) }
    let(:meetings_nav_path) { organisation_meetings_path(organisation) }

    # An org nav entry rendered hidden behind the "mehr …" reveal: its <li> carries
    # data-more-item and wraps the link to the given path. Scoped to the org path so
    # a project's own "mehr …" group can never make this match.
    def more_item_wrapping(path)
      /data-more-item[^>]*>\s*<a[^>]*#{Regexp.escape(path)}/m
    end

    def grant_time_access!
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session_permission, user: sidebar_user, project: project_a, can_view_own: true)
      end
    end

    def grant_meetings_access!
      ActsAsTenant.with_tenant(organisation) { base_permission.update!(meetings_access: 'read_only') }
    end

    # "Zeiten" is a fixed entry of the org navigation now (user, 01.09.2026:
    # the times entry must always be visible). With it out of the collapsible
    # group, "Alle Meetings" would be the group's only member, and a single extra
    # entry stays inline by the rule the group had, so the "mehr …" reveal has no
    # case left in the org navigation and is gone.
    it 'shows "Zeiten" AND "Alle Meetings" inline when both are present, no "mehr …" reveal' do
      grant_time_access!
      grant_meetings_access!
      sign_in sidebar_user
      get sidebar_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('navigation.times'))
      expect(response.body).to include(I18n.t('navigation.all_meetings'))
      expect(response.body).not_to match(more_item_wrapping(times_path))
      expect(response.body).not_to match(more_item_wrapping(meetings_nav_path))
      # The project sidebar keeps its own "mehr …" group; the org block must not
      # render one. Scoped to the org entries: no reveal wraps either of them.
      expect(response.body).not_to match(/reveal-more[^<]*<[^>]*>\s*(?:<[^>]*>\s*)*#{Regexp.escape(times_path)}/m)
    end

    it 'shows "Zeiten" inline when it is the only extra entry' do
      grant_time_access! # meetings access withheld
      sign_in sidebar_user
      get sidebar_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('navigation.times'))
      expect(response.body).not_to match(more_item_wrapping(times_path))
    end

    it 'shows "Alle Meetings" inline when it is the only extra entry' do
      grant_meetings_access! # time access withheld
      sign_in sidebar_user
      get sidebar_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('navigation.all_meetings'))
      expect(response.body).not_to match(more_item_wrapping(meetings_nav_path))
    end

    it 'lists "Zeiten" before "Alle Meetings"' do
      grant_time_access!
      grant_meetings_access!
      sign_in sidebar_user
      get sidebar_path

      expect(response.body.index(I18n.t('navigation.times'))).to be < response.body.index(I18n.t('navigation.all_meetings'))
    end
  end

  describe 'performance (no N+1 across rows)' do
    # reader_all reads meetings in both projects, so several rows from different
    # projects render together — Prosopite (scanning every example) fails here if
    # project name or participants are not preloaded via includes (Eng-Review D10).
    let(:reader_all) { user_with_access('read_only', on: [project_a, project_b]) }

    it 'renders meetings from several projects without an N+1 on project/participants' do
      # Pause during setup (participant creates re-read the tenant org — benign
      # setup noise); the GET below is what must be N+1-free.
      Prosopite.pause do
        create_meeting(project: project_a, title: 'Alpha One', participants: ['Anna Mueller'])
        create_meeting(project: project_a, title: 'Alpha Two', participants: ['Bob Builder'])
        create_meeting(project: project_b, title: 'Beta One', participants: ['Clara Klein'])
      end

      sign_in reader_all
      get overview_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Alpha One', 'Alpha Two', 'Beta One')
      expect(response.body).to include('Projekt Alpha', 'Projekt Beta')
    end
  end

  describe 'row navigation' do
    it 'links each row into the project master-detail with the meeting selected' do
      meeting = create_meeting(project: project_a, title: 'Alpha Kickoff')
      sign_in reader_a
      get overview_path
      expect(response.body).to include(
        organisation_project_meetings_path(organisation, project_a, meeting_id: meeting.id)
      )
    end
  end

  describe 'empty states' do
    before { sign_in reader_a }

    it 'shows the first-time empty state when there are no meetings at all' do
      get overview_path
      expect(response.body).to include(I18n.t('views.organisations.meetings_overview.index.empty_first_time_title'))
    end

    it 'shows the no-results empty state (with reset) when a filter matches nothing' do
      create_meeting(project: project_a, title: 'Alpha Kickoff')
      get overview_path, params: { search: 'zzz-nothing-matches' }
      expect(response.body).to include(I18n.t('views.organisations.meetings_overview.index.empty_no_results'))
      expect(response.body).to include(I18n.t('views.organisations.meetings_overview.index.empty_reset'))
    end
  end
end
