# frozen_string_literal: true

require 'rails_helper'

# MeetingTicketLinksController — manual Meeting↔Ticket links (Gespräche Slice 3).
# Covers positive AND negative area access, the turbo-frame refresh, friendly
# duplicate handling (unique index → no 500), and the cross-project tampering
# guard (a foreign ticket id → 404, no Reference created). Denial surfaces as a
# redirect (area gate) or 404 (record scoped out of @project), never a literal 403.
#
# Tenanted count queries (Reference) run inside ActsAsTenant.with_tenant because
# require_tenant is true and the per-request tenant is cleared after each request.
RSpec.describe 'Organisations::MeetingTicketLinks', type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  # meetings = 'read_only'/'read_write'/:none; tickets is optional (a meetings user
  # need not have tickets access — the create endpoint only needs :meetings write).
  def user_with_access(meetings, tickets: nil, on: project)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      perms = {}
      perms[:meetings_access] = meetings unless meetings == :none
      perms[:tickets_access] = tickets if tickets
      create(:project_permission, user: user, project: on, **perms) if perms.any?
    end
    user
  end

  let(:writer) { user_with_access('read_write') }
  let(:reader) { user_with_access('read_only') }
  # Sees linked tickets as live links (needs :tickets read too, like the TS picker).
  let(:viewer) { user_with_access('read_only', tickets: 'read_only') }
  # Can use the picker: meetings write AND tickets read (the picker lists tickets).
  let(:editor) { user_with_access('read_write', tickets: 'read_only') }

  let(:meeting) do
    ActsAsTenant.with_tenant(organisation) { create(:meeting, project: project, organisation: organisation, creator: writer) }
  end
  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, organisation: organisation, creator: writer, title: 'Fix login') }
  end

  let(:create_path) { organisation_project_meeting_ticket_links_path(organisation, project, meeting) }

  # require_tenant is true and the per-request tenant is reset to nil AFTER each
  # request — so a change(Reference, :count) matcher straddling a post would raise
  # NoTenantSet on its second read. without_tenant re-establishes a valid scope on
  # every re-evaluation of the change{} block (only this example's rows exist).
  def reference_count
    ActsAsTenant.without_tenant { Reference.count }
  end

  describe 'POST create' do
    # A move of the meeting (Actors::MoveMeeting) refuses a meeting with links,
    # under the meeting's row lock. A link has to take the same lock and look
    # again: a move that committed while it waited has taken the meeting into
    # another project, and the ticket stays behind in this one.
    it 'links nothing when the meeting moved away while the link waited for its lock' do
      elsewhere = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      ticket
      allow_any_instance_of(Meeting).to receive(:lock!).and_wrap_original do |original, *args|
        Meeting.where(id: original.receiver.id).update_all(project_id: elsewhere.id)
        original.call(*args)
      end
      sign_in writer

      expect { post create_path, params: { ticket_id: ticket.id } }.not_to(change { reference_count })
      expect(response).to have_http_status(:not_found)
    end

    it 'links a ticket for a meetings writer, snapshotting its title' do
      sign_in writer
      expect { post create_path, params: { ticket_id: ticket.id } }.to change { reference_count }.by(1)
      # Keep the tenant active while the polymorphic target lazy-loads (Ticket is tenanted).
      ActsAsTenant.with_tenant(organisation) do
        reference = meeting.outgoing_references.first
        expect(reference.target).to eq(ticket)
        expect(reference.target_title_snapshot).to eq(ticket.display_title)
      end
    end

    it 'refreshes the ticket-links turbo-frame (turbo_stream request)' do
      sign_in writer
      post create_path, params: { ticket_id: ticket.id }, as: :turbo_stream
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(meeting, :ticket_links))
      expect(response.body).to include(ticket.display_title)
    end

    it 'rejects a meetings reader with a redirect and creates no link' do
      sign_in reader
      expect { post create_path, params: { ticket_id: ticket.id } }.not_to(change { reference_count })
      expect(response).to have_http_status(:redirect)
    end

    it 'returns a friendly message on a duplicate link (unique index), no 500' do
      sign_in writer
      post create_path, params: { ticket_id: ticket.id }
      expect { post create_path, params: { ticket_id: ticket.id } }.not_to(change { reference_count })
      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(I18n.t('flash.meeting_ticket_links.already_linked'))
    end

    it 'handles an empty picker submission gracefully (no 500), creating no link' do
      sign_in writer
      expect { post create_path, params: { ticket_id: '' } }.not_to(change { reference_count })
      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(I18n.t('flash.meeting_ticket_links.blank_selection'))
    end

    it 'redirects to the meeting with a success notice on the HTML path' do
      # Pins the success contract of respond_link_result: :notice (not :alert) and the
      # meeting-scoped redirect target — a flipped flash type or wrong path breaks here.
      sign_in writer
      post create_path, params: { ticket_id: ticket.id }
      expect(response).to redirect_to(
        organisation_project_meetings_path(organisation, project, meeting_id: meeting.id)
      )
      expect(flash[:notice]).to eq(I18n.t('flash.meeting_ticket_links.created'))
    end

    it 'truncates an over-long ticket title into the 255-char snapshot column (no RecordInvalid → no 500)' do
      # display_title = "#<number> <title>"; Reference caps target_title_snapshot at
      # 255 (validation). Without the &.truncate(255) in the controller, a long title
      # would raise RecordInvalid and 500. A title at Ticket::TITLE_MAX_LENGTH: the
      # number prefix alone pushes the display title past the cap.
      long_ticket = ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: writer,
                        title: 'L' * Ticket::TITLE_MAX_LENGTH)
      end
      sign_in writer
      expect { post create_path, params: { ticket_id: long_ticket.id } }.to change { reference_count }.by(1)
      expect(response).to have_http_status(:redirect)

      snapshot = ActsAsTenant.with_tenant(organisation) { meeting.outgoing_references.first.target_title_snapshot }
      expect(snapshot.length).to be <= 255
      expect(snapshot).to eq(long_ticket.display_title.truncate(255))
    end

    it 'maps a race duplicate (DB unique index) to a friendly message, not a 500' do
      # The app-level pre-check normally catches a double-link; this proves the
      # rescue behind it. Force PAST the pre-check (stub only Meeting#outgoing_references'
      # exists?, nothing else) with the row already present, so create! hits the DB
      # unique index → RecordNotUnique → the controller must catch it, not 500.
      ActsAsTenant.with_tenant(organisation) do
        meeting.outgoing_references.create!(organisation: organisation, target: ticket,
                                            target_title_snapshot: ticket.display_title)
      end
      allow_any_instance_of(Meeting).to receive(:outgoing_references).and_wrap_original do |original|
        original.call.tap { |relation| allow(relation).to receive(:exists?).and_return(false) }
      end

      sign_in writer
      expect { post create_path, params: { ticket_id: ticket.id } }.not_to(change { reference_count })
      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(I18n.t('flash.meeting_ticket_links.already_linked'))
    end

    context 'tampering: ticket id from a foreign project' do
      let(:other_project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
      let(:foreign_ticket) do
        ActsAsTenant.with_tenant(organisation) { create(:ticket, project: other_project, organisation: organisation, creator: writer) }
      end

      it 'is rejected with 404 and creates no Reference' do
        sign_in writer
        expect { post create_path, params: { ticket_id: foreign_ticket.id } }.not_to(change { reference_count })
        expect(response).to have_http_status(:not_found)
      end
    end

    it 'is 404 when the meeting in the URL belongs to a different project (set_meeting scoping)' do
      # The meeting is scoped through @project.meetings; a meeting_id from another
      # project under THIS project's URL must not resolve. Guards this controller's
      # own set_meeting — a mutation to Meeting.find (unscoped) would pass otherwise.
      other_project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      foreign_meeting = ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: other_project, organisation: organisation, creator: writer)
      end
      sign_in writer
      path = organisation_project_meeting_ticket_links_path(organisation, project, foreign_meeting)
      expect { post path, params: { ticket_id: ticket.id } }.not_to(change { reference_count })
      expect(response).to have_http_status(:not_found)
    end

    it 'redirects an unauthenticated user to login' do
      post create_path, params: { ticket_id: ticket.id }
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe 'DELETE destroy' do
    let!(:reference) do
      ActsAsTenant.with_tenant(organisation) do
        meeting.outgoing_references.create!(organisation: organisation, target: ticket,
                                            target_title_snapshot: ticket.display_title)
      end
    end

    def destroy_path(ref)
      organisation_project_meeting_ticket_link_path(organisation, project, meeting, ref)
    end

    it 'removes the link for a meetings writer' do
      sign_in writer
      expect { delete destroy_path(reference) }.to change { reference_count }.by(-1)
    end

    it 'rejects a meetings reader with a redirect and keeps the link' do
      sign_in reader
      expect { delete destroy_path(reference) }.not_to(change { reference_count })
      expect(response).to have_http_status(:redirect)
    end

    it 'returns 404 for a reference id belonging to a different meeting' do
      other_meeting = ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation, creator: writer)
      end
      sign_in writer
      # reference belongs to `meeting`, requested under `other_meeting` → not found.
      delete organisation_project_meeting_ticket_link_path(organisation, project, other_meeting, reference)
      expect(response).to have_http_status(:not_found)
    end

    it 'destroys only the targeted reference and leaves the other links intact' do
      # Guards against a destroy that nukes more than the one row (e.g. delete_all).
      second_reference = ActsAsTenant.with_tenant(organisation) do
        other_ticket = create(:ticket, project: project, organisation: organisation, creator: writer)
        meeting.outgoing_references.create!(organisation: organisation, target: other_ticket,
                                            target_title_snapshot: other_ticket.display_title)
      end
      sign_in writer
      expect { delete destroy_path(reference) }.to change { reference_count }.by(-1)
      ActsAsTenant.with_tenant(organisation) do
        expect(meeting.outgoing_references.reload).to contain_exactly(second_reference)
      end
    end
  end

  # The meeting show route renders the full master-detail (incl. _meeting_show and
  # the ticket-links section) server-side when a meeting is selected.
  describe 'meeting detail rendering (Verknüpfte Tickets section)' do
    def link_ticket!
      ActsAsTenant.with_tenant(organisation) do
        meeting.outgoing_references.create!(organisation: organisation, target: ticket,
                                            target_title_snapshot: ticket.display_title)
      end
    end

    it 'lists a linked ticket with a live link (viewer has tickets read)' do
      link_ticket!
      sign_in viewer
      get organisation_project_meeting_path(organisation, project, meeting)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(meeting, :ticket_links))
      expect(response.body).to include(ticket.display_title)
      expect(response.body).to include(organisation_project_tickets_path(organisation, project, ticket_id: ticket.id))
    end

    it 'escapes the section turbo-frame when navigating to a linked ticket (data-turbo-frame="_top")' do
      # The link sits inside the section's own <turbo-frame>. Without _top,
      # Turbo loads the tickets page INTO that frame, finds no matching frame
      # in the response and renders "Content missing" instead of navigating.
      link_ticket!
      sign_in viewer
      get organisation_project_meeting_path(organisation, project, meeting)

      href = organisation_project_tickets_path(organisation, project, ticket_id: ticket.id)
      anchor = Nokogiri::HTML(response.body).at_css(%(a[href="#{href}"]))
      expect(anchor).not_to be_nil
      expect(anchor['data-turbo-frame']).to eq('_top')
    end

    # Both cases key on the picker's own <form action=create_path method=post>. An earlier version
    # asserted on the submit label instead ("unique to the picker") — that stopped being true once
    # the external-participant claim section shipped its own 'Verknüpfen' button, and the read-only
    # case started failing on a string from a completely different feature. Matching the form
    # element is exact: the destroy button posts to create_path + '/:id', not to create_path.
    def picker_form_css
      "form[action='#{create_path}'][method='post']"
    end

    it 'renders the ticket picker (form + submit) for a meetings writer with tickets read' do
      ticket # ensure a linkable ticket exists
      sign_in editor
      get organisation_project_meeting_path(organisation, project, meeting)

      expect(Capybara.string(response.body)).to have_css(picker_form_css, visible: :all)
    end

    it 'does NOT render the picker for a meetings reader (read-only)' do
      sign_in viewer # meetings read_only + tickets read_only
      get organisation_project_meeting_path(organisation, project, meeting)

      expect(Capybara.string(response.body)).to have_no_css(picker_form_css, visible: :all)
    end

    it 'shows the linked ticket title as plain text (no link) for a meetings-only user without tickets read' do
      link_ticket!
      sign_in reader
      get organisation_project_meeting_path(organisation, project, meeting)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(ticket.display_title)
      # No cross-area leak of the tickets URL to a user who cannot read tickets.
      expect(response.body).not_to include(organisation_project_tickets_path(organisation, project, ticket_id: ticket.id))
    end

    it 'shows a tombstone (snapshot + gelöscht) after the linked ticket is deleted — no dead link, no crash' do
      link_ticket!
      snapshot = ticket.display_title
      ActsAsTenant.with_tenant(organisation) { ticket.destroy! }

      sign_in reader
      get organisation_project_meeting_path(organisation, project, meeting)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(snapshot)
      expect(response.body).to include(I18n.t('views.organisations.meetings.ticket_links.deleted_badge'))
      # The deleted ticket must NOT be a live link any more.
      expect(response.body).not_to include(organisation_project_tickets_path(organisation, project, ticket_id: ticket.id))
    end

    it 'renders the remove control for a meetings writer but not for a read-only user' do
      reference = link_ticket!
      remove_path = organisation_project_meeting_ticket_link_path(organisation, project, meeting, reference)

      sign_in editor # meetings write
      get organisation_project_meeting_path(organisation, project, meeting)
      # button_to renders <form action="<remove_path>">; the ref id makes it specific.
      expect(response.body).to include(remove_path)

      sign_in viewer # meetings read-only
      get organisation_project_meeting_path(organisation, project, meeting)
      expect(response.body).not_to include(remove_path)
    end

    it 'renders several linked tickets without an N+1 (includes(:target); Prosopite guards it)' do
      # Prosopite scans every example (spec/support/prosopite.rb): if someone drops
      # includes(:target) from the section, loading N target titles becomes an N+1 and
      # THIS example fails. One linked ticket could never surface that — hence three.
      tickets = ActsAsTenant.with_tenant(organisation) do
        Array.new(3) do |i|
          tk = create(:ticket, project: project, organisation: organisation, creator: writer, title: "Ticket #{i}")
          meeting.outgoing_references.create!(organisation: organisation, target: tk,
                                              target_title_snapshot: tk.display_title)
          tk
        end
      end
      sign_in viewer
      get organisation_project_meeting_path(organisation, project, meeting)

      expect(response).to have_http_status(:ok)
      tickets.each { |tk| expect(response.body).to include(tk.display_title) }
    end

    it 'shows only Ticket targets — a non-ticket outgoing reference is filtered out (no crash)' do
      # The section is where(target_type: Ticket): it protects the deferred
      # Meeting→Document slice AND renders ref.target.display_title, which a Note has
      # NOT. Drop the filter and a non-ticket target would 500 here.
      link_ticket!
      note = ActsAsTenant.with_tenant(organisation) do
        n = create(:note, project: project, organisation: organisation, creator: writer, title: 'NOTIZ-nicht-in-tickets')
        meeting.outgoing_references.create!(organisation: organisation, target: n, target_title_snapshot: n.title)
        n
      end
      sign_in viewer
      get organisation_project_meeting_path(organisation, project, meeting)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(ticket.display_title)
      expect(response.body).not_to include(note.title)
    end

    it 'omits already-linked tickets from the picker but offers unlinked ones' do
      # Connected block: the picker's option list must reflect the current links, so
      # a user cannot pick a ticket that is already linked (which would just error).
      link_ticket! # links `ticket`
      unlinked = ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: writer, title: 'Noch frei')
      end
      sign_in editor # meetings write + tickets read → picker renders
      get organisation_project_meeting_path(organisation, project, meeting)

      # Picker options carry data-value="<ticket id>"; the already-linked ticket's id
      # appears elsewhere (linked list) but NOT as a selectable option.
      expect(response.body).to include(%(data-value="#{unlinked.id}"))
      expect(response.body).not_to include(%(data-value="#{ticket.id}"))
    end
  end

  # Connected block: the two directions must stay consistent through the REAL
  # endpoints — linking on the meeting surfaces the backlink on the ticket, and
  # unlinking removes it again. Exercises create + destroy + both views end-to-end.
  describe 'bidirectional round-trip (create endpoint ↔ ticket backlink)' do
    let(:user) { user_with_access('read_write', tickets: 'read_only') }

    def ticket_detail_body
      get organisation_project_ticket_path(organisation, project, ticket)
      response.body
    end

    it 'surfaces the backlink after linking and removes it after unlinking' do
      sign_in user

      post create_path, params: { ticket_id: ticket.id }
      expect(ticket_detail_body).to include("meeting-references-#{ticket.id}")

      reference = ActsAsTenant.with_tenant(organisation) { meeting.outgoing_references.first }
      delete organisation_project_meeting_ticket_link_path(organisation, project, meeting, reference)
      expect(ticket_detail_body).not_to include("meeting-references-#{ticket.id}")
    end

    it 'escapes the ticket detail turbo-frame when navigating to the linking meeting (data-turbo-frame="_top")' do
      # The backlink renders inside ticket_display_frame (the lane, on the list
      # and on the board). Without _top, the meetings page (which has no such
      # frame) comes back as "Content missing" instead of a full navigation.
      sign_in user
      post create_path, params: { ticket_id: ticket.id }

      href = organisation_project_meetings_path(organisation, project, meeting_id: meeting.id)
      anchor = Nokogiri::HTML(ticket_detail_body).at_css(%(a[href="#{href}"]))
      expect(anchor).not_to be_nil
      expect(anchor['data-turbo-frame']).to eq('_top')
    end
  end
end
