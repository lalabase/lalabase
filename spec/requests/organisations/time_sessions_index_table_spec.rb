# frozen_string_literal: true

require 'rails_helper'

# Regression guards for the time-session list render paths:
# - Index and create-stream use the same grouping (group_and_sort_by_ticket);
#   the no-ticket group always sorts to the end. Previously
#   create.turbo_stream.erb sorted it to the start with its own inline logic.
# - show_creator survives the sort/pagination path (respond_to_sort_and_paginate).
RSpec.describe 'Organisations::TimeSessions index table', type: :request do
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
  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, creator: user, title: 'Alpha-Aufgabe')
    end
  end
  let!(:session_with_ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:time_session, organisation: organisation, project: project, ticket: ticket,
                            creator: user, duration: 60)
    end
  end
  let!(:session_without_ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:time_session, organisation: organisation, project: project, ticket: nil,
                            creator: user, duration: 30)
    end
  end

  let(:without_subject_label) { I18n.t('views.organisations.time_sessions.index_table.without_subject') }
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

  describe 'GET index' do
    it 'gruppiert nach Ticket und sortiert die Ohne-Ticket-Gruppe ans Ende' do
      get organisation_time_sessions_path(organisation, project_id_filter: project.id, date_range: 'all')

      expect(response).to have_http_status(:ok)
      ticket_pos = response.body.index('Alpha-Aufgabe')
      no_ticket_pos = response.body.index(without_subject_label)
      expect(ticket_pos).to be_present
      expect(no_ticket_pos).to be_present
      expect(ticket_pos).to be < no_ticket_pos
    end

    # Was "Sortier-Pfad": the list has no sortable columns any more (S2, T4), so
    # what this covers is the Turbo-Stream path that paging renders.
    it 'zeigt den Ersteller eigener Sessions im Blaetter-Pfad nur mit show_creator=1' do
      sort_params = { date_range: 'all', project_id_filter: project.id }
      # Only the desktop branch respects show_creator; the mobile cards always
      # show the creator — so restrict to the desktop part.
      mobile_marker = '<!-- Mobile: Card View -->'

      get organisation_time_sessions_path(organisation),
          params: sort_params.merge(show_creator: '1'), headers: turbo_stream_headers
      expect(response.body).to include(mobile_marker)
      expect(response.body.split(mobile_marker).first).to include(user.full_name)

      get organisation_time_sessions_path(organisation),
          params: sort_params, headers: turbo_stream_headers
      expect(response.body.split(mobile_marker).first).not_to include(user.full_name)
    end
  end

  describe 'POST create (turbo_stream, context=index_page)' do
    # Zweitreview of #675, finding 1: the re-rendered list carries @project (from
    # the form), and the pagination base path became the list address WITH the
    # project filter in its query. The two callers appended "?..." blindly, so
    # every paging link read "...?project_id_filter=P?items=20": a click filtered
    # on a project id of "P?items=20" and lost the page.
    it 'renders paging links with ONE query string that keeps the project filter' do
      post organisation_time_sessions_path(organisation),
           params: {
             time_session: { duration_string: '0:30', occurred_on: Date.current.to_s,
                             description: 'Aus der Org-Liste gebucht', project_id: project.id },
             context: 'index_page'
           },
           headers: turbo_stream_headers

      expect(response).to have_http_status(:ok)
      # The per-page picker is a <select> whose option VALUES are addresses; the
      # page links are hrefs. Both come from the same two helper methods.
      paging_links = response.body.scan(/(?:href|value)="([^"]*items=\d+[^"]*)"/).flatten.map { |h| CGI.unescapeHTML(h) }
      expect(paging_links).to be_present, 'the re-rendered list shows no per-page links'
      paging_links.each do |href|
        expect(href.count('?')).to eq(1), href
        expect(href.scan("project_id_filter=#{project.id}").size).to eq(1), href
      end
    end

    it 'ersetzt time_sessions_list_frame mit derselben Gruppen-Sortierung wie der Index' do
      post organisation_project_time_sessions_path(organisation, project),
           params: {
             time_session: { duration_string: '0:45', occurred_on: Date.current.to_s,
                             description: 'Neuer Eintrag' },
             context: 'index_page'
           },
           headers: turbo_stream_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('target="time_sessions_list_frame"')

      ticket_pos = response.body.index('Alpha-Aufgabe')
      no_ticket_pos = response.body.index(without_subject_label)
      expect(ticket_pos).to be_present
      expect(no_ticket_pos).to be_present
      expect(ticket_pos).to be < no_ticket_pos
    end
  end
end
