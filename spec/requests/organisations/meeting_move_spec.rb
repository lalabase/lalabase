# frozen_string_literal: true

require 'rails_helper'

# Moving a meeting into another project (MeetingsController#move_preflight and
# #move, Actors::MoveMeeting). The right: move_meetings (or account admin) plus
# meetings write in the source; the target needs meetings write too, is looked
# up among the active projects the user may see (another organisation's project
# is not found), and is never archived. A meeting with linked tickets stays.
RSpec.describe 'Organisations::Meetings move', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:source) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Allgemein') } }
  let(:target) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Relaunch') } }
  let(:read_only_target) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Nur lesen') }
  end
  let(:foreign_project) do
    ActsAsTenant.with_tenant(other_organisation) { create(:project, organisation: other_organisation, name: 'Fremd') }
  end

  # move: grant move_meetings through the role; access: meetings access per project.
  def member(move:, access:)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
      create(:permission, role: role, category: 'meetings', action: 'move_meetings', allowed: true) if move
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      access.each { |project, level| create(:project_permission, user: user, project: project, meetings_access: level) }
    end
    user
  end

  let(:mover) { member(move: true, access: { source => 'read_write', target => 'read_write', read_only_target => 'read_only' }) }
  let(:meeting) do
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting, project: source, organisation: organisation, creator: mover, title: 'Erstgespräch')
    end
  end

  let(:preflight_path) { move_preflight_organisation_project_meeting_path(organisation, source, meeting) }
  let(:move_path) { move_organisation_project_meeting_path(organisation, source, meeting) }

  def meeting_project_id
    ActsAsTenant.without_tenant { meeting.reload.project_id }
  end

  def frame_get(path)
    get path, headers: { 'Turbo-Frame' => "meeting-move-modal-#{meeting.id}" }
  end

  describe 'GET move_preflight' do
    it 'offers the projects the mover may write meetings in, and only those' do
      foreign_project
      sign_in mover
      frame_get preflight_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("meeting-move-modal-#{meeting.id}")
      expect(response.body).to include('Relaunch')
      expect(response.body).not_to include('Nur lesen')
      expect(response.body).not_to include('Fremd')
      expect(response.body).not_to include(%(value="#{source.id}"))
    end

    it 'names the booked time, the billed part and the open suggestions' do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session, project: source, organisation: organisation, meeting: meeting, creator: mover)
        create(:time_session, project: source, organisation: organisation, meeting: meeting, creator: mover,
                              billed: true, billed_at: 1.day.ago)
        create(:meeting_ticket_suggestion, meeting: meeting)
      end
      sign_in mover
      frame_get preflight_path

      expect(response.body).to include(I18n.t('views.organisations.meetings.move.time_sessions', count: 2, billed: 1))
      expect(response.body).to include(I18n.t('views.organisations.meetings.move.open_suggestions', count: 1))
    end

    it 'says up front that a meeting with linked tickets cannot move, and offers no form' do
      ActsAsTenant.with_tenant(organisation) do
        ticket = create(:ticket, project: source, organisation: organisation, creator: mover)
        Reference.create!(source: meeting, target: ticket, target_title_snapshot: ticket.title)
      end
      sign_in mover
      frame_get preflight_path

      expect(response.body).to include(I18n.t('views.organisations.meetings.move.has_ticket_links', count: 1))
      expect(response.body).not_to include('name="target_project_id"')
    end

    it 'refuses a member without move_meetings' do
      user = member(move: false, access: { source => 'read_write', target => 'read_write' })
      sign_in user
      frame_get preflight_path

      expect(response).to have_http_status(:redirect)
    end
  end

  describe 'POST move' do
    it 'moves the meeting and opens it in the target project' do
      sign_in mover
      post move_path, params: { target_project_id: target.id, modal_token: 'abc' }

      expect(meeting_project_id).to eq(target.id)
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(organisation_project_meetings_path(organisation, target, meeting_id: meeting.id))
      expect(flash[:notice]).to eq(I18n.t('flash.meetings.moved', project: 'Relaunch'))
    end

    it 'stays on "Alle Meetings" when the move started there' do
      sign_in mover
      post move_path, params: { target_project_id: target.id, modal_token: 'abc', list_context: 'organisation' }

      expect(meeting_project_id).to eq(target.id)
      expect(response).to redirect_to(organisation_meetings_path(organisation, meeting_id: meeting.id))
    end

    it 'lets an account admin move without the role permission' do
      admin = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: admin, organisation: organisation, role: create(:admin_role, organisation: organisation))
      end
      sign_in admin
      post move_path, params: { target_project_id: target.id, modal_token: 'abc' }

      expect(meeting_project_id).to eq(target.id)
    end

    it 'refuses a member without move_meetings' do
      user = member(move: false, access: { source => 'read_write', target => 'read_write' })
      sign_in user
      post move_path, params: { target_project_id: target.id, modal_token: 'abc' }

      expect(meeting_project_id).to eq(source.id)
    end

    it 'refuses a mover who may only read meetings in the source' do
      user = member(move: true, access: { source => 'read_only', target => 'read_write' })
      sign_in user
      post move_path, params: { target_project_id: target.id, modal_token: 'abc' }

      expect(meeting_project_id).to eq(source.id)
    end

    it 'shows the move in both project feeds, only to those who read meetings there' do
      tickets_only = member(move: false, access: {})
      ActsAsTenant.with_tenant(organisation) do
        create(:project_permission, user: tickets_only, project: target, tickets_access: 'read_only',
                                    meetings_access: 'no_access')
      end
      sign_in mover
      post move_path, params: { target_project_id: target.id, modal_token: 'abc' }

      get organisation_project_activities_path(organisation, target)
      expect(response.body).to include('Erstgespräch')
      expect(response.body).to include(I18n.t('views.organisations.tickets.timeline.meeting_moved_in', project: 'Allgemein'))

      get organisation_project_activities_path(organisation, source)
      expect(response.body).to include(I18n.t('views.organisations.tickets.timeline.meeting_moved_out', project: 'Relaunch'))

      sign_in tickets_only
      get organisation_project_activities_path(organisation, target)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('Erstgespräch')
    end

    context 'with a target the move refuses' do
      def expect_refused(target_id, message)
        sign_in mover
        post move_path, params: { target_project_id: target_id, modal_token: 'abc' }, as: :turbo_stream

        expect(meeting_project_id).to eq(source.id)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("meeting-move-modal-#{meeting.id}-abc")
        expect(response.body).to include(CGI.escapeHTML(message))
      end

      it 'refuses a project the mover may only read meetings in' do
        expect_refused(read_only_target.id, I18n.t('services.actors.move_meeting.forbidden_target'))
      end

      it "does not find another organisation's project" do
        expect_refused(foreign_project.id, I18n.t('services.actors.move_meeting.forbidden_target'))
      end

      it 'refuses an archived project' do
        ActsAsTenant.with_tenant(organisation) { target.update!(archived_at: Time.current) }

        expect_refused(target.id, I18n.t('services.actors.move_meeting.forbidden_target'))
      end

      it 'refuses a meeting with a linked ticket' do
        ActsAsTenant.with_tenant(organisation) do
          ticket = create(:ticket, project: source, organisation: organisation, creator: mover)
          Reference.create!(source: meeting, target: ticket, target_title_snapshot: ticket.title)
        end

        expect_refused(target.id, I18n.t('services.actors.move_meeting.has_ticket_links'))
      end
    end
  end
end
