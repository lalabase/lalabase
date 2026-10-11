# frozen_string_literal: true

require 'rails_helper'

# Ticket detail "Gespräche" backlinks (Gespräche Slice 3): the section lists
# meetings that link TO the ticket. The CRITICAL path is the negative one — a
# user without :meetings read must not see the section, nor even learn that
# meeting links exist (backlink leak). The show route renders the full detail
# (incl. _ticket_content_for_frame) server-side, so the section is assertable here.
RSpec.describe 'Ticket meeting backlinks (detail rendering)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:creator) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  # Builds a signed-up user with the given per-area access on `project`.
  def user_with(**access)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      create(:project_permission, { user: user, project: project }.merge(access))
    end
    user
  end

  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: creator, title: 'Fix login')
    end
  end
  let(:meeting) do
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting, project: project, organisation: organisation, creator: creator, title: 'Kickoff-Gespraech-XZ')
    end
  end

  # Link the meeting → ticket (the backlink under test).
  before do
    ActsAsTenant.with_tenant(organisation) do
      meeting.outgoing_references.create!(organisation: organisation, target: ticket,
                                          target_title_snapshot: ticket.display_title)
    end
  end

  def detail_path(ticket_record)
    organisation_project_ticket_path(organisation, project, ticket_record)
  end

  context 'user with :meetings read' do
    let(:user) { user_with(tickets_access: 'read_only', meetings_access: 'read_only') }

    it 'renders the backlink section linking to the meeting' do
      sign_in user
      get detail_path(ticket)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("meeting-references-#{ticket.id}")
      expect(response.body).to include('Kickoff-Gespraech-XZ')
      expect(response.body).to include(organisation_project_meetings_path(organisation, project, meeting_id: meeting.id))
    end
  end

  context 'user WITHOUT :meetings read (backlink leak guard)' do
    let(:user) { user_with(tickets_access: 'read_only') } # meetings_access defaults to no_access

    it 'does NOT render the backlink section nor the meeting title' do
      sign_in user
      get detail_path(ticket)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("meeting-references-#{ticket.id}")
      expect(response.body).not_to include('Kickoff-Gespraech-XZ')
    end
  end

  context 'when the linking meeting is deleted' do
    let(:user) { user_with(tickets_access: 'read_only', meetings_access: 'read_only') }

    it 'shows nothing orphaned on the ticket (dependent: :destroy removes the backlink)' do
      ActsAsTenant.with_tenant(organisation) { meeting.destroy! }
      sign_in user
      get detail_path(ticket)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("meeting-references-#{ticket.id}")
      expect(response.body).not_to include('Kickoff-Gespraech-XZ')
    end
  end

  context 'a ticket with no backlinks at all' do
    let(:user) { user_with(tickets_access: 'read_only', meetings_access: 'read_only') }

    it 'renders no empty "Gespräche" section (guarded by references.any?)' do
      unlinked = ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: creator, title: 'Ohne Bezug')
      end
      sign_in user
      get detail_path(unlinked)

      expect(response).to have_http_status(:ok)
      # The section must not appear as an empty shell when there are no backlinks.
      expect(response.body).not_to include("meeting-references-#{unlinked.id}")
    end
  end

  context 'a non-meeting reference also points at the ticket' do
    let(:user) { user_with(tickets_access: 'read_only', meetings_access: 'read_only') }

    it 'lists only meeting sources — a note-sourced reference is filtered out (no crash)' do
      # The backlink is where(source_type: Meeting) and renders source.occurred_at,
      # which a Note has NOT. Without the filter a note source would 500 here.
      note = ActsAsTenant.with_tenant(organisation) do
        n = create(:note, project: project, organisation: organisation, creator: creator, title: 'NOTIZ-Quelle')
        Reference.create!(organisation: organisation, source: n, target: ticket,
                          target_title_snapshot: ticket.display_title)
        n
      end
      sign_in user
      get detail_path(ticket)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Kickoff-Gespraech-XZ') # the meeting backlink
      expect(response.body).not_to include(note.title)
    end
  end

  context 'a ticket linked from several meetings' do
    let(:user) { user_with(tickets_access: 'read_only', meetings_access: 'read_only') }

    it 'lists all linking meetings without an N+1 (includes(:source); Prosopite guards it)' do
      # `meeting` (from the shared before) already links; add two more so a dropped
      # includes(:source) becomes an N+1 that Prosopite fails on. One backlink cannot.
      extra_titles = ActsAsTenant.with_tenant(organisation) do
        Array.new(2) do |i|
          m = create(:meeting, project: project, organisation: organisation, creator: creator, title: "Gespraech-Extra-#{i}")
          m.outgoing_references.create!(organisation: organisation, target: ticket,
                                        target_title_snapshot: ticket.display_title)
          m.title
        end
      end
      sign_in user
      get detail_path(ticket)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Kickoff-Gespraech-XZ') # the original backlink
      extra_titles.each { |title| expect(response.body).to include(title) }
    end
  end
end
