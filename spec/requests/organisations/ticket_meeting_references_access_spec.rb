# frozen_string_literal: true

require 'rails_helper'

# A ticket moved out of its meeting's project keeps the meeting link (nothing in the move
# touches Reference). The meeting then lives in project A and the ticket in project B. The
# ticket's "meetings" section must judge each meeting against the meeting's OWN project:
# read access to meetings in B says nothing about the meetings of A, and the link to a
# meeting of A has to name A.
RSpec.describe 'Ticket meeting references after a move', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:creator) { create(:user) }
  let(:project_a) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:project_b) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  let(:meeting) do
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting, project: project_a, organisation: organisation, creator: creator,
                       title: 'Planning-Meeting-QV')
    end
  end

  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project_a, organisation: organisation, creator: creator, title: 'Moved ticket')
    end
  end

  def grant(user, project, **access)
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission, { user: user, project: project }.merge(access))
    end
  end

  # A member whose role may carry organisation-wide permissions ("all projects"),
  # or the account admin role.
  def member(global: [], admin: false)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = if admin
               create(:admin_role, organisation: organisation)
             else
               create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
             end
      global.each { |action| create(:permission, role: role, category: 'projects', action: action, allowed: true) }
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    user
  end

  # Link in A, then move the ticket to B through the real mover.
  before do
    ActsAsTenant.with_tenant(organisation) do
      grant(creator, project_a, tickets_access: 'read_write', meetings_access: 'read_write')
      grant(creator, project_b, tickets_access: 'read_write', meetings_access: 'read_write')
      meeting.outgoing_references.create!(organisation: organisation, target: ticket,
                                          target_title_snapshot: ticket.display_title)
      Tickets::Mover.call(ticket: ticket, target_project: project_b, current_user: creator)
    end
    ticket.reload
  end

  def ticket_page
    get organisation_project_ticket_path(organisation, project_b, ticket)
    expect(response).to have_http_status(:ok)
    response.body
  end

  it 'moved the ticket and kept the link (precondition)' do
    expect(ticket.project_id).to eq(project_b.id)
    ActsAsTenant.with_tenant(organisation) do
      expect(Reference.pointing_to(ticket).where(source: meeting)).to exist
    end
  end

  context 'viewer reads meetings in B but has no access to A at all' do
    let(:viewer) do
      member.tap { |user| grant(user, project_b, tickets_access: 'read_only', meetings_access: 'read_only') }
    end

    it 'does not name the meeting of A' do
      sign_in viewer
      body = ticket_page

      expect(body).not_to include('Planning-Meeting-QV')
      expect(body).not_to include("meeting-references-#{ticket.id}")
    end
  end

  context 'viewer reads meetings in B and tickets, but not meetings, in A' do
    let(:viewer) do
      member.tap do |user|
        grant(user, project_b, tickets_access: 'read_only', meetings_access: 'read_only')
        grant(user, project_a, tickets_access: 'read_only')
      end
    end

    it 'does not name the meeting of A' do
      sign_in viewer
      body = ticket_page

      expect(body).not_to include('Planning-Meeting-QV')
      expect(body).not_to include("meeting-references-#{ticket.id}")
    end
  end

  context 'viewer reads meetings in A but not in B' do
    let(:viewer) do
      member.tap do |user|
        grant(user, project_b, tickets_access: 'read_only')
        grant(user, project_a, meetings_access: 'read_only')
      end
    end

    it 'names the meeting of A and links into A' do
      sign_in viewer
      body = ticket_page

      expect(body).to include('Planning-Meeting-QV')
      expect(body).to include(organisation_project_meetings_path(organisation, project_a, meeting_id: meeting.id))
      expect(body).not_to include(organisation_project_meetings_path(organisation, project_b, meeting_id: meeting.id))
    end
  end

  context 'viewer reads meetings in both projects' do
    let(:viewer) do
      member.tap do |user|
        grant(user, project_b, tickets_access: 'read_only', meetings_access: 'read_only')
        grant(user, project_a, meetings_access: 'read_only')
      end
    end

    it "links the meeting into its own project A, not into the ticket's project B" do
      sign_in viewer
      body = ticket_page

      expect(body).to include('Planning-Meeting-QV')
      expect(body).to include(organisation_project_meetings_path(organisation, project_a, meeting_id: meeting.id))
      expect(body).not_to include(organisation_project_meetings_path(organisation, project_b, meeting_id: meeting.id))
    end
  end

  context 'viewer reads meetings in all projects through the role' do
    let(:viewer) do
      member(global: %w[read_access_meetings_all_projects]).tap do |user|
        grant(user, project_b, tickets_access: 'read_only')
      end
    end

    it 'names the meeting of A and links into A' do
      sign_in viewer
      body = ticket_page

      expect(body).to include('Planning-Meeting-QV')
      expect(body).to include(organisation_project_meetings_path(organisation, project_a, meeting_id: meeting.id))
    end
  end

  context 'viewer reads meetings in all projects through the role, but not in A' do
    let(:viewer) do
      member(global: %w[read_access_meetings_all_projects]).tap do |user|
        grant(user, project_b, tickets_access: 'read_only')
        grant(user, project_a, meetings_access: 'no_access')
      end
    end

    it 'does not name the meeting of A' do
      sign_in viewer
      body = ticket_page

      expect(body).not_to include('Planning-Meeting-QV')
      expect(body).not_to include("meeting-references-#{ticket.id}")
    end
  end

  context 'viewer is an account admin' do
    let(:viewer) { member(admin: true) }

    it 'names the meeting of A and links into A' do
      sign_in viewer
      body = ticket_page

      expect(body).to include('Planning-Meeting-QV')
      expect(body).to include(organisation_project_meetings_path(organisation, project_a, meeting_id: meeting.id))
    end
  end

  # The other side of the same link: the meeting in A lists the ticket that now
  # lives in B. The ticket is judged against B, its link names B, and a reader
  # who cannot see it learns nothing newer than the title it had when linked.
  describe "the meeting's linked tickets" do
    before do
      ActsAsTenant.with_tenant(organisation) { ticket.update!(title: 'Renamed-in-B-QV') }
    end

    def meeting_page
      get organisation_project_meeting_path(organisation, project_a, meeting)
      expect(response).to have_http_status(:ok)
      response.body
    end

    context 'viewer reads tickets and meetings in A, nothing in B' do
      let(:viewer) do
        member.tap { |user| grant(user, project_a, tickets_access: 'read_only', meetings_access: 'read_only') }
      end

      it 'shows the title from the time of linking, without a link' do
        sign_in viewer
        body = meeting_page

        expect(body).to include('Moved ticket')
        expect(body).not_to include('Renamed-in-B-QV')
        expect(body).not_to include("ticket_id=#{ticket.id}")
      end
    end

    context 'viewer reads meetings in A and tickets in B' do
      let(:viewer) do
        member.tap do |user|
          grant(user, project_a, meetings_access: 'read_only')
          grant(user, project_b, tickets_access: 'read_only')
        end
      end

      it 'links the ticket into its own project B' do
        sign_in viewer
        body = meeting_page

        expect(body).to include('Renamed-in-B-QV')
        expect(body).to include(organisation_project_tickets_path(organisation, project_b, ticket_id: ticket.id))
        expect(body).not_to include(organisation_project_tickets_path(organisation, project_a, ticket_id: ticket.id))
      end
    end
  end
end
