# frozen_string_literal: true

require 'rails_helper'

# T3 regression net for time_sessions#update (plan: doc/actors_t3_save_time_session_plan.md §4).
#
# What: request coverage for the previously untested update action — the three
#   group-transition paths, the success-redirect cascade (R7) and the T3 fixes.
# Why (failing-first against the pre-actor controller):
#   R2 — assigning a billed target group silently invoiced the session
#        (add_time_session_to_group copied group.billed?).
#   R3 — group transition + invalid attribute committed the group change anyway
#        (service transaction + separate update = two commits).
#   R4 — an ABSENT :time_session_group_id key silently removed the session from
#        its group ([P1] twin of the T2 :billed absent-key fix, plan §9.8-4).
#   R5 — plan deviation, discovered in the red run: TimeSessionPolicy#update?
#        denies billed sessions BEFORE the controller body runs (302 via the
#        Pundit rescue), so the bare-raise English message was never reachable
#        over HTTP. R5 here pins that policy layer; the :session_billed actor
#        guard behind it is pinned in the actor unit spec (defense-in-depth).
RSpec.describe 'Organisations::TimeSessions update', type: :request do
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

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  def with_tenant(&)
    ActsAsTenant.with_tenant(organisation, &)
  end

  def create_time_session_record(**attrs)
    with_tenant do
      create(:time_session,
             { organisation: organisation, project: project, creator: user,
               duration: 60, time_session_group: nil }.merge(attrs))
    end
  end

  def unbilled_group(name = 'Offene Abrechnung')
    with_tenant { create(:time_session_group, organisation: organisation, creator: user, name: name) }
  end

  def billed_group
    with_tenant { create(:time_session_group, :billed, organisation: organisation, creator: user) }
  end

  describe 'R2: assigning a billed target group' do
    it 'refuses with 422 and leaves the session untouched' do
      time_session = create_time_session_record
      group = billed_group

      patch organisation_project_time_session_path(organisation, project, time_session),
            params: { time_session: { time_session_group_id: group.id, description: 'Geändert' } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('services.save_time_session.group_billed'))
      with_tenant do
        reloaded = TimeSession.find(time_session.id)
        expect(reloaded.time_session_group_id).to be_nil
        expect(reloaded.billed).to be(false)
        expect(reloaded.description).to eq('Test time session')
      end
    end
  end

  describe 'R3: group transition + invalid attribute' do
    it 'rolls the group change back when another attribute fails validation' do
      time_session = create_time_session_record
      group = unbilled_group

      patch organisation_project_time_session_path(organisation, project, time_session),
            params: { time_session: { time_session_group_id: group.id, occurred_on: '' } }

      expect(response).to have_http_status(:unprocessable_content)
      with_tenant do
        expect(TimeSession.find(time_session.id).time_session_group_id).to be_nil
      end
    end

    # Review finding 6: pins the :validation_failed no-op arm of
    # apply_save_failure — a pure validation failure must surface ONLY the
    # model error, never the generic fallback on top (mutation: dropping the
    # :validation_failed arm adds the generic message to every form error).
    it 'shows only the model error on a pure validation failure (no generic fallback)' do
      time_session = create_time_session_record

      patch organisation_project_time_session_path(organisation, project, time_session),
            params: { time_session: { occurred_on: '' } }

      expect(response).to have_http_status(:unprocessable_content)
      occurred_on_error = with_tenant do
        TimeSession.new(occurred_on: nil).tap(&:validate).errors.full_messages_for(:occurred_on).first
      end
      expect(occurred_on_error).to be_present
      expect(response.body).to include(occurred_on_error)
      expect(response.body).not_to include(I18n.t('services.save_time_session.generic_error'))
    end
  end

  # Review finding 3: pins the except(:ticket_id, :meeting_id) list in the
  # update actor call — ensure_valid_subject resolves subject ids against
  # @project's own scopes (foreign id -> cleared + logged); passing the raw ids
  # to the write again would re-assign and PERSIST them (belongs_to optional,
  # no scope validation). Mutation: shrinking the except list turns these red.
  describe 'foreign subject ids are not written (cross-tenant guard)' do
    let(:other_project) do
      with_tenant { create(:project, organisation: organisation) }
    end

    it 'does not persist a ticket_id from a foreign project' do
      foreign_ticket = with_tenant { create(:ticket, project: other_project, creator: user) }
      time_session = create_time_session_record

      patch organisation_project_time_session_path(organisation, project, time_session),
            params: { time_session: { ticket_id: foreign_ticket.id, description: 'Tamper' } }

      expect(response).to have_http_status(:found)
      with_tenant do
        reloaded = TimeSession.find(time_session.id)
        expect(reloaded.ticket_id).to be_nil
        expect(reloaded.description).to eq('Tamper')
      end
    end

    it 'does not persist a meeting_id from a foreign project' do
      foreign_meeting = with_tenant do
        create(:meeting, project: other_project, organisation: organisation, creator: user)
      end
      time_session = create_time_session_record

      patch organisation_project_time_session_path(organisation, project, time_session),
            params: { time_session: { meeting_id: foreign_meeting.id, description: 'Tamper' } }

      expect(response).to have_http_status(:found)
      with_tenant do
        expect(TimeSession.find(time_session.id).meeting_id).to be_nil
      end
    end
  end

  describe 'R4: absent :time_session_group_id key ([P1] twin)' do
    it 'keeps the group when the key is not submitted at all' do
      group = unbilled_group
      time_session = create_time_session_record(time_session_group: group)

      patch organisation_project_time_session_path(organisation, project, time_session),
            params: { time_session: { description: 'Nur Text geändert' } }

      expect(response).to have_http_status(:found)
      with_tenant do
        reloaded = TimeSession.find(time_session.id)
        expect(reloaded.time_session_group_id).to eq(group.id)
        expect(reloaded.description).to eq('Nur Text geändert')
      end
    end
  end

  describe 'R5: removing a billed session from its billed group' do
    it 'is denied by the policy before the write and changes nothing' do
      group = billed_group
      time_session = create_time_session_record(time_session_group: group, billed: true,
                                                billed_at: group.billed_at, invoice_number: group.invoice_number)

      patch organisation_project_time_session_path(organisation, project, time_session),
            params: { time_session: { time_session_group_id: '', description: 'Versuch' } }

      # TimeSessionPolicy#update? refuses billed sessions -> Pundit rescue redirect.
      expect(response).to have_http_status(:found)
      # The bare-raise English service message must never leak into a response.
      expect(response.body).not_to include('Cannot remove time session from billed group')
      with_tenant do
        reloaded = TimeSession.find(time_session.id)
        expect(reloaded.time_session_group_id).to eq(group.id)
        expect(reloaded.billed).to be(true)
        expect(reloaded.description).not_to eq('Versuch')
      end
    end
  end

  # Review finding 2 (failing-first): group_change_from_params reads the RAW
  # params (needed for the absent-key check), so a non-scalar value used to
  # reach TimeSessionGroup.find as an Array -> NoMethodError in the actor
  # (dev/test 500, production :internal_error noise). Normalized to nil now:
  # garbage behaves like a blank value (explicit removal — main parity, where
  # permit dropped the non-scalar key and the removal path ran).
  describe 'non-scalar time_session_group_id value' do
    it 'treats an array value like a blank value instead of raising' do
      group = unbilled_group
      time_session = create_time_session_record(time_session_group: group)

      patch organisation_project_time_session_path(organisation, project, time_session),
            params: { time_session: { time_session_group_id: [group.id] } }

      expect(response).to have_http_status(:found)
      with_tenant do
        expect(TimeSession.find(time_session.id).time_session_group_id).to be_nil
      end
    end
  end

  # R7: coverage pins for the three update paths and the success-redirect
  # cascade — behaviour-preserving (green before and after the actor cut).
  describe 'R7: update paths and success redirects' do
    it 'assigns the session to an unbilled group without billing it' do
      time_session = create_time_session_record
      group = unbilled_group

      patch organisation_project_time_session_path(organisation, project, time_session),
            params: { time_session: { time_session_group_id: group.id } }

      expect(response).to have_http_status(:found)
      with_tenant do
        reloaded = TimeSession.find(time_session.id)
        expect(reloaded.time_session_group_id).to eq(group.id)
        expect(reloaded.billed).to be(false)
      end
    end

    it 'removes the session from its unbilled group on an explicit blank value' do
      group = unbilled_group
      time_session = create_time_session_record(time_session_group: group)

      patch organisation_project_time_session_path(organisation, project, time_session),
            params: { time_session: { time_session_group_id: '' } }

      expect(response).to have_http_status(:found)
      with_tenant do
        expect(TimeSession.find(time_session.id).time_session_group_id).to be_nil
      end
    end

    it 'updates plain attributes and sets the updated flash' do
      time_session = create_time_session_record

      patch organisation_project_time_session_path(organisation, project, time_session),
            params: { time_session: { duration_string: '2:30' } }

      expect(response).to have_http_status(:found)
      expect(flash[:notice]).to eq(I18n.t('flash.time_sessions.updated'))
      with_tenant do
        expect(TimeSession.find(time_session.id).duration).to eq(150)
      end
    end

    it 'redirects to the time list, filtered to the project, in index_page context' do
      time_session = create_time_session_record

      patch organisation_project_time_session_path(organisation, project, time_session),
            params: { context: 'index_page', time_session: { description: 'Kontext Index' } }

      expect(response).to redirect_to(organisation_time_sessions_path(organisation, project_id_filter: project.id))
    end

    it 'redirects to the ticket when the session has one' do
      ticket = with_tenant { create(:ticket, project: project, creator: user) }
      time_session = create_time_session_record(ticket: ticket)

      patch organisation_project_time_session_path(organisation, project, time_session),
            params: { time_session: { description: 'Ticket-Kontext' } }

      expect(response).to redirect_to(organisation_project_ticket_path(organisation, project, ticket))
    end

    it 'redirects to the time list, filtered to the project, without ticket and context' do
      time_session = create_time_session_record

      patch organisation_project_time_session_path(organisation, project, time_session),
            params: { time_session: { description: 'Standard' } }

      expect(response).to redirect_to(organisation_time_sessions_path(organisation, project_id_filter: project.id))
    end

    # Review finding 5: cascade precedence — index_page context beats the
    # ticket redirect (both old duplicate cascades checked context FIRST).
    # Mutation: dropping the context check from redirect_path_after_update's
    # first branch sends this to the ticket page instead.
    it 'prefers the index_page context over the ticket redirect' do
      ticket = with_tenant { create(:ticket, project: project, creator: user) }
      time_session = create_time_session_record(ticket: ticket)

      patch organisation_project_time_session_path(organisation, project, time_session),
            params: { context: 'index_page', time_session: { description: 'Index vor Ticket' } }

      expect(response).to redirect_to(organisation_time_sessions_path(organisation, project_id_filter: project.id))
    end
  end

  # Review finding 4: pins BOTH turbo_stream success branches of #update
  # (D-T3-4 replaced the inline modal-close/reload <script> with
  # turbo_stream.refresh — without these pins, swapping or breaking the
  # branches stays green). media_type pinned per the modal turbo-stream rule
  # (a missing template silently degrades to 204, see memory reference).
  describe 'turbo_stream success responses' do
    let(:turbo_headers) { { 'Accept' => 'text/vnd.turbo-stream.html' } }

    it 'renders a refresh stream in index_page context (modal closes via full reload)' do
      time_session = create_time_session_record

      patch organisation_project_time_session_path(organisation, project, time_session),
            params: { context: 'index_page', time_session: { description: 'Turbo Index' } },
            headers: turbo_headers

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(response.body).to include('<turbo-stream action="refresh"')
      # The flash survives the full reload as a persistent flash, not a stream.
      expect(flash[:notice]).to eq(I18n.t('flash.time_sessions.updated'))
    end

    it 'renders the update template (flash update stream) without index_page context' do
      time_session = create_time_session_record

      patch organisation_project_time_session_path(organisation, project, time_session),
            params: { time_session: { description: 'Turbo Detail' } },
            headers: turbo_headers

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(response.body).to include('<turbo-stream action="update" target="flash"')
      expect(response.body).not_to include('<turbo-stream action="refresh"')
    end
  end

  # Review finding 7: the :session_billed arm of apply_save_failure sits
  # BEHIND TimeSessionPolicy#update? (billed sessions never reach the actor
  # over HTTP) and is only reachable in the §9.8-1 race window — a session
  # invoiced between the policy check and the actor's in-transaction re-read.
  # That window cannot be scheduled deterministically in a request spec, so
  # the actor is stubbed to return exactly the coded failure the race
  # produces; the assertion covers the controller mapping code -> message.
  describe 'session_billed failure mapping (race window)' do
    it 'renders the localized session_billed message, not the generic fallback' do
      time_session = create_time_session_record
      failure = Actors::BaseActor::Result.new(
        success: false, errors: [I18n.t('services.save_time_session.session_billed')],
        code: :session_billed
      )
      allow(Actors::SaveTimeSession).to receive(:call).and_return(failure)

      patch organisation_project_time_session_path(organisation, project, time_session),
            params: { time_session: { time_session_group_id: '' } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('services.save_time_session.session_billed'))
      expect(response.body).not_to include(I18n.t('services.save_time_session.generic_error'))
    end
  end

  # Moved here from spec/controllers/time_sessions_controller_spec.rb, where two examples
  # invoked a private #ensure_valid_ticket_id with stubbed params. That method is gone — its
  # logic sits inline in #edit — so the examples pinned a name rather than a behaviour and
  # died with NoMethodError. Over HTTP the same contract holds without naming internals:
  # opening the edit form with a ticket_id preselects that ticket, while a blank or foreign
  # one preselects nothing. The foreign case doubles as a cross-project leakage guard.
  describe 'GET edit with a ticket_id parameter' do
    it 'preselects the ticket named in the parameter' do
      time_session = create_time_session_record
      ticket = with_tenant { create(:ticket, organisation: organisation, project: project, creator: user) }

      get edit_organisation_project_time_session_path(organisation, project, time_session),
          params: { ticket_id: ticket.id }

      expect(response).to have_http_status(:ok)
      expect(assigns(:time_session).ticket).to eq(ticket)
    end

    it 'preselects nothing when the parameter is blank' do
      time_session = create_time_session_record

      get edit_organisation_project_time_session_path(organisation, project, time_session),
          params: { ticket_id: '' }

      expect(response).to have_http_status(:ok)
      expect(assigns(:time_session).ticket).to be_nil
    end

    it 'preselects nothing for a ticket from another project, instead of raising' do
      time_session = create_time_session_record
      foreign_ticket = with_tenant do
        other_project = create(:project, organisation: organisation)
        create(:ticket, organisation: organisation, project: other_project, creator: user)
      end

      get edit_organisation_project_time_session_path(organisation, project, time_session),
          params: { ticket_id: foreign_ticket.id }

      expect(response).to have_http_status(:ok)
      expect(assigns(:time_session).ticket).to be_nil
    end
  end
  # A booking may move to another project of the organisation, but only where
  # the member may edit it as well: the same time permission update? asks for
  # in its current project. Its subject has to belong to the target, so a
  # ticket of the old project never travels along.
  describe 'moving a booking to another project' do
    let(:member) { create(:user) }
    let(:target) { with_tenant { create(:project, organisation: organisation) } }

    before do
      with_tenant do
        create(:membership, user: member, organisation: organisation, role: create(:role, organisation: organisation), active: true)
        create(:time_session_permission, user: member, project: project)
      end
      sign_in member
    end

    def own_booking(**attrs)
      create_time_session_record(creator: member, **attrs)
    end

    def allow_in_target(**flags)
      with_tenant { create(:time_session_permission, user: member, project: target, **flags) }
    end

    def move(time_session, to: target, **attrs)
      patch organisation_project_time_session_path(organisation, project, time_session),
            params: { time_session: { project_id: to.id, **attrs } }
    end

    it 'moves an own booking where the member may edit own bookings' do
      allow_in_target
      time_session = own_booking
      move(time_session)
      expect(time_session.reload.project_id).to eq(target.id)
    end

    it 'keeps the booking without time permissions in the target' do
      time_session = own_booking
      move(time_session)
      expect(response).not_to have_http_status(:ok)
      expect(time_session.reload.project_id).to eq(project.id)
    end

    it 'keeps the booking when the target allows viewing only' do
      allow_in_target(can_create_own: false, can_edit_own: false)
      time_session = own_booking
      move(time_session)
      expect(time_session.reload.project_id).to eq(project.id)
    end

    it 'keeps the booking when the target is a project of another organisation' do
      other = create(:organisation)
      foreign = ActsAsTenant.with_tenant(other) { create(:project, organisation: other) }
      time_session = own_booking
      move(time_session, to: foreign)
      expect(time_session.reload.project_id).to eq(project.id)
    end

    it 'takes no ticket of the old project along, but one of the target' do
      allow_in_target
      old_ticket = with_tenant { create(:ticket, organisation: organisation, project: project, creator: member) }
      time_session = own_booking(ticket: old_ticket)
      move(time_session)
      expect(time_session.reload).to have_attributes(project_id: project.id, ticket_id: old_ticket.id)
      new_ticket = with_tenant { create(:ticket, organisation: organisation, project: target, creator: member) }
      move(time_session, ticket_id: new_ticket.id)
      expect(time_session.reload).to have_attributes(project_id: target.id, ticket_id: new_ticket.id)
    end
  end
end
