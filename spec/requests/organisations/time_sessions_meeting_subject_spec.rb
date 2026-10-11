# frozen_string_literal: true

require 'rails_helper'

# Gespräche Slice 2 — a meeting is a first-class time subject (replaces the
# fake-ticket workaround). Covers: booking time on a meeting through the hours
# chip in its detail header, the subject display in the time list (meeting title +
# bi-chat-quote so meeting time is never anonymous in billing), cross-project
# tampering of meeting_id, and the write gate.
RSpec.describe 'Organisations::TimeSessions meeting subject', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
  end

  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end
  let(:meeting) do
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting, project: project, organisation: organisation, creator: user, title: 'Kickoff Kundengespräch')
    end
  end

  let(:turbo_stream_headers) { { 'Accept' => 'text/vnd.turbo-stream.html' } }

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
    # Skip N+1 detection for these request examples WITHOUT leaking the scan:
    # stubbing Prosopite.finish left the scan open (Prosopite.scan is a no-op
    # while one is active), poisoning whichever spec file ran next.
    Prosopite.pause
  end

  after { Prosopite.resume }

  # acts_as_tenant resets the tenant after each request; evaluate counts inside it.
  def time_session_count
    ActsAsTenant.with_tenant(organisation) { TimeSession.count }
  end

  describe 'meeting page rendering (hours chip is the only time entry)' do
    it 'offers booking at the hours chip and renders no header time button' do
      # A standalone meeting visit renders the full index page (list head + this
      # meeting). The header "Zeit" button and its modal are gone (16.09.2026): the
      # hours chip in the meta row already offers "Aufwand buchen" at 0 booked
      # minutes, as the ticket header does since 05.09.2026. The chip's wrapper
      # anchor must render even then, because create.turbo_stream.erb replaces it
      # after the FIRST booking.
      get organisation_project_meeting_path(organisation, project, meeting)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("meeting_#{meeting.id}_time_summary")
      expect(response.body).to include(I18n.t('components.subject_time_summary.capture_effort'))
      expect(response.body).not_to include('data-controller="time-session-modal"')
      expect(response.body).not_to include('time_session_modal_form')
    end

    it 'shows the aggregated total of the time booked on the meeting as the hours chip' do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session, organisation: organisation, project: project, creator: user, meeting: meeting, duration: 30)
        create(:time_session, organisation: organisation, project: project, creator: user, meeting: meeting, duration: 45)
      end

      get organisation_project_meeting_path(organisation, project, meeting)

      # 30 + 45 = 75 min → "1:15 h" chip (clock format like the ticket header,
      # user mockup 05.09.2026); a distinctive value the individual sessions
      # (30/45 min) never produce, so it only appears if the sum is correct.
      expect(response.body).to include('1:15 h')
    end
  end

  describe 'booking time on a meeting (POST create with meeting_id)' do
    it 'creates a session tied to the meeting, with no ticket' do
      expect do
        post organisation_project_time_sessions_path(organisation, project),
             params: { time_session: { duration_string: '1:30', occurred_on: Date.current.to_s,
                                       description: 'Gespräch geführt', meeting_id: meeting.id },
                       context: 'meeting' },
             headers: turbo_stream_headers
      end.to change { time_session_count }.by(1)

      ActsAsTenant.with_tenant(organisation) do
        ts = TimeSession.order(:created_at).last
        expect(ts.meeting_id).to eq(meeting.id)
        expect(ts.ticket_id).to be_nil
        expect(ts.duration).to eq(90)
      end
    end

    it 'refreshes the header hours chip with the newly booked total' do
      post organisation_project_time_sessions_path(organisation, project),
           params: { time_session: { duration_string: '0:30', occurred_on: Date.current.to_s,
                                     description: 'frisch gebucht', meeting_id: meeting.id },
                     context: 'meeting' },
           headers: turbo_stream_headers

      expect(response).to have_http_status(:ok)
      # Not just the replace target: the refreshed chip must actually carry the new
      # total (30 min → "0:30 h", clock format since the 05.09.2026 mockup),
      # otherwise a stream that renders an empty wrapper would pass a bare
      # id-string check.
      expect(response.body).to include("meeting_#{meeting.id}_time_summary")
      expect(response.body).to include('0:30 h')
    end
  end

  describe 'subject display in the time list' do
    let!(:meeting_session) do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session, organisation: organisation, project: project, creator: user,
                              meeting: meeting, duration: 45, description: 'Notiz zum Gespräch')
      end
    end

    it 'shows the meeting title with the bi-chat-quote icon (not anonymous)' do
      get organisation_time_sessions_path(organisation),
          params: { project_id_filter: project.id, date_range: 'all', status_filters: %w[billed in_billing without_billing] },
          headers: turbo_stream_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Kickoff Kundengespräch')
      expect(response.body).to include('bi-chat-quote')
    end
  end

  describe 'search over the subject title (meetings.title)' do
    let!(:meeting_session) do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session, organisation: organisation, project: project, creator: user,
                              meeting: meeting, duration: 20, description: 'nichts Besonderes')
      end
    end
    let!(:other_session) do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session, organisation: organisation, project: project, creator: user,
                              ticket: nil, duration: 10, description: 'voellig anderes Thema')
      end
    end

    it 'finds a meeting-booked session by the meeting title and excludes non-matches' do
      get organisation_time_sessions_path(organisation),
          params: { project_id_filter: project.id, date_range: 'all', status_filters: %w[billed in_billing without_billing], search: 'Kickoff' },
          headers: turbo_stream_headers

      expect(response.body).to include('Kickoff Kundengespräch')
      expect(response.body).not_to include('voellig anderes Thema')
    end
  end

  # Both tampering variants assert POSITIVELY that a scrubbed session is created
  # (meeting_id nil), not merely that no session points at the foreign meeting —
  # otherwise a request that 500s for an unrelated reason would pass falsely. If
  # the @project.meetings scoping were dropped (a global Meeting.find), the foreign
  # id would resolve and both assertions here would fail.
  describe 'cross-project tampering (meeting_id from a foreign project, same org)' do
    let(:other_project) do
      ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    end
    let(:foreign_meeting) do
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: other_project, organisation: organisation, creator: user, title: 'Fremdes Gespräch')
      end
    end

    it 'scrubs the foreign meeting_id and creates a subject-less session instead' do
      expect do
        post organisation_project_time_sessions_path(organisation, project),
             params: { time_session: { duration_string: '0:15', occurred_on: Date.current.to_s,
                                       description: 'tamper', meeting_id: foreign_meeting.id },
                       context: 'meeting' },
             headers: turbo_stream_headers
      end.to change { time_session_count }.by(1)

      ActsAsTenant.with_tenant(organisation) do
        expect(TimeSession.where(meeting_id: foreign_meeting.id)).to be_empty
        expect(TimeSession.order(:created_at).last.meeting_id).to be_nil
      end
    end
  end

  describe 'cross-tenant tampering (meeting_id from a different organisation)' do
    let(:other_org) { create(:organisation) }
    let(:foreign_org_meeting) do
      ActsAsTenant.with_tenant(other_org) do
        op = create(:project, organisation: other_org)
        create(:meeting, project: op, organisation: other_org, creator: create(:user), title: 'Fremd-Org Gespräch')
      end
    end

    it 'scrubs a meeting_id that belongs to another organisation' do
      foreign_id = foreign_org_meeting.id

      post organisation_project_time_sessions_path(organisation, project),
           params: { time_session: { duration_string: '0:15', occurred_on: Date.current.to_s,
                                     description: 'tamper', meeting_id: foreign_id },
                     context: 'meeting' },
           headers: turbo_stream_headers

      ActsAsTenant.with_tenant(organisation) do
        expect(TimeSession.where(meeting_id: foreign_id)).to be_empty
        expect(TimeSession.order(:created_at).last&.meeting_id).to be_nil
      end
    end
  end

  describe 'XOR at the request boundary (both subjects submitted)' do
    let(:ticket) do
      ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, creator: user, title: 'Doppelbetreff') }
    end

    it 'rejects a create carrying BOTH a ticket and a meeting and persists nothing' do
      # The controller must not bypass #at_most_one_subject; if the validation is
      # removed the DB check constraint still refuses the row — either way nothing
      # is persisted.
      expect do
        post organisation_project_time_sessions_path(organisation, project),
             params: { time_session: { duration_string: '0:20', occurred_on: Date.current.to_s,
                                       description: 'both', ticket_id: ticket.id, meeting_id: meeting.id } },
             headers: turbo_stream_headers
      end.not_to(change { time_session_count })
    end
  end

  # The subject validation runs through ONE unified ensure_valid_subject for both
  # sides, with per-key gating: an id is only touched when its key is submitted.
  # These lock that a subject submitted alone never nulls the other subject.
  describe 'update preserves the un-submitted subject (per-key gating)' do
    let(:meeting_session) do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session, organisation: organisation, project: project, creator: user,
                              meeting: meeting, duration: 30, description: 'alt')
      end
    end

    it 'keeps the meeting when only the description is updated (meeting_id absent)' do
      patch organisation_project_time_session_path(organisation, project, meeting_session),
            params: { time_session: { description: 'neu' }, context: 'index_page' }

      ActsAsTenant.with_tenant(organisation) do
        reloaded = TimeSession.find(meeting_session.id)
        expect(reloaded.description).to eq('neu')
        expect(reloaded.meeting_id).to eq(meeting.id)
      end
    end

    it 'keeps the meeting when a blank ticket_id is submitted but no meeting_id' do
      # THE per-key-gating killer: dropping the `key?` guard would read the absent
      # meeting_id as blank and null the meeting here.
      patch organisation_project_time_session_path(organisation, project, meeting_session),
            params: { time_session: { description: 'x', ticket_id: '' }, context: 'index_page' }

      ActsAsTenant.with_tenant(organisation) do
        expect(TimeSession.find(meeting_session.id).meeting_id).to eq(meeting.id)
      end
    end
  end

  describe 'update through the unified subject path — ticket side' do
    let(:ticket_a) do
      ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, creator: user, title: 'Ticket A') }
    end
    let(:ticket_b) do
      ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, creator: user, title: 'Ticket B') }
    end
    let(:ticket_session) do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session, organisation: organisation, project: project, creator: user,
                              ticket: ticket_a, duration: 30, description: 'ticket')
      end
    end

    it 'moves the session to a different ticket' do
      patch organisation_project_time_session_path(organisation, project, ticket_session),
            params: { time_session: { ticket_id: ticket_b.id }, context: 'index_page' }

      ActsAsTenant.with_tenant(organisation) do
        expect(TimeSession.find(ticket_session.id).ticket_id).to eq(ticket_b.id)
      end
    end

    it 'clears the ticket when a blank ticket_id is submitted' do
      patch organisation_project_time_session_path(organisation, project, ticket_session),
            params: { time_session: { ticket_id: '' }, context: 'index_page' }

      ActsAsTenant.with_tenant(organisation) do
        expect(TimeSession.find(ticket_session.id).ticket_id).to be_nil
      end
    end
  end

  describe 'write gate (no :time_sessions write)' do
    let(:member_role) { create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation) }
    let(:member) { create(:user) }
    let!(:member_membership) do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: member, organisation: organisation, role: member_role, active: true)
      end
    end

    it 'denies booking and creates nothing' do
      sign_in member

      expect do
        post organisation_project_time_sessions_path(organisation, project),
             params: { time_session: { duration_string: '0:15', occurred_on: Date.current.to_s,
                                       meeting_id: meeting.id },
                       context: 'meeting' }
      end.not_to(change { time_session_count })

      expect(response).to have_http_status(:redirect)
    end
  end

  # The whole point of the subject refactor: ticket groups and meeting groups sort
  # together as ONE alphabetical sequence (plan §9 Q9), the no-subject group last.
  # Ticket-only (the regression spec) and a single meeting can't catch a mutation
  # that sorts meetings in a separate pass or dumps them after all tickets.
  describe 'mixed ticket + meeting groups sort together by title' do
    let(:beta_ticket) do
      ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, creator: user, title: 'Beta-Ticket') }
    end
    let(:alpha_meeting) do
      ActsAsTenant.with_tenant(organisation) { create(:meeting, project: project, organisation: organisation, creator: user, title: 'Alpha-Gespräch') }
    end
    let(:gamma_meeting) do
      ActsAsTenant.with_tenant(organisation) { create(:meeting, project: project, organisation: organisation, creator: user, title: 'Gamma-Gespräch') }
    end

    # One fixed moment for all four: the list groups by subject AND month, and the
    # factory's `Time.current + n.hours` sequence splits the four across a month
    # boundary whenever the suite's counter lands there, which reorders the headers.
    let(:booked_on) { Time.current.beginning_of_month + 14.days }

    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session, organisation: organisation, project: project, creator: user, ticket: beta_ticket, duration: 10, occurred_on: booked_on)
        create(:time_session, organisation: organisation, project: project, creator: user, meeting: alpha_meeting, duration: 10, occurred_on: booked_on)
        create(:time_session, organisation: organisation, project: project, creator: user, meeting: gamma_meeting, duration: 10, occurred_on: booked_on)
        create(:time_session, organisation: organisation, project: project, creator: user, ticket: nil, duration: 10, occurred_on: booked_on)
      end
    end

    it 'interleaves meeting and ticket headers alphabetically, no-subject last' do
      get organisation_time_sessions_path(organisation),
          params: { project_id_filter: project.id, date_range: 'all', status_filters: %w[billed in_billing without_billing] },
          headers: turbo_stream_headers

      alpha = response.body.index('Alpha-Gespräch') # meeting
      beta = response.body.index('Beta-Ticket') # ticket
      gamma = response.body.index('Gamma-Gespräch') # meeting
      none = response.body.index(I18n.t('views.organisations.time_sessions.index_table.without_subject'))

      expect([alpha, beta, gamma, none]).to all(be_present)
      expect(alpha).to be < beta
      expect(beta).to be < gamma
      expect(gamma).to be < none
    end
  end

  # Plan: billing views (time_session_groups/*) stay ticket-agnostic. A meeting
  # session assigned to a billing group must render WITHOUT error (it appears like a
  # no-ticket session) — this guards against an unguarded `session.ticket.number`
  # ever 500-ing the customer export once meetings carry billable time.
  describe 'billing views tolerate a meeting-subject session' do
    let(:billing_group) do
      ActsAsTenant.with_tenant(organisation) { create(:time_session_group, organisation: organisation, creator: user) }
    end
    let!(:grouped_meeting_session) do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session, organisation: organisation, project: project, creator: user,
                              meeting: meeting, time_session_group: billing_group,
                              duration: 60, description: 'Gesprächszeit abrechnen')
      end
    end

    it 'renders the chronological billing view without error' do
      get chronological_organisation_time_session_group_path(organisation, billing_group)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Gesprächszeit abrechnen')
    end

    it 'renders the customer export without error' do
      get customer_export_organisation_time_session_group_path(organisation, billing_group)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Gesprächszeit abrechnen')
    end
  end
end
