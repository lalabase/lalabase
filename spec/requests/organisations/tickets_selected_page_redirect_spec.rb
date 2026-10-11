# frozen_string_literal: true

require 'rails_helper'

# Regression guard for the "reload loses the list" hunt (03.09.2026).
#
# ObjectListController#calculate_and_redirect_to_object_page plucked ids off
# the includes-relation; pluck forces the eager-load JOINs, and the
# tags/assignees fan-out duplicated every id. The selected ticket's FIRST
# occurrence then sat far past its true position, and every reload of a
# ?ticket_id= URL was redirected to an empty overflow page ("Keine Aufgaben
# gefunden" beside an intact detail pane). The show route has carried a
# hand-built join-free query for this calculation all along; the concern's
# twin never got the rule. Second defect in the same redirect: sort is a
# nested hash, and permit(:sort) silently dropped it.
RSpec.describe 'Tickets index selected-page redirect', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation,
                        role: create(:admin_role, organisation: organisation))
    sign_in user
  end

  it 'does not redirect a first-page ticket to an overflow page despite join fan-out' do
    ActsAsTenant.current_tenant = organisation

    # 8 tickets, 3 tags each: the plucked JOIN rows numbered 24 before the
    # fix, pushing the oldest ticket's first occurrence past the per-page
    # default of 20 - and the redirect built page 2+ for a one-page list.
    tickets = Array.new(8) do |i|
      create(:ticket, project: project, organisation: organisation, creator: user,
                      created_at: (i + 1).hours.ago)
    end
    tickets.each do |ticket|
      3.times do |i|
        tag = create(:tag, name: "fanout-#{ticket.id[0, 6]}-#{i}", organisation: organisation)
        create(:tagging, tag: tag, taggable: ticket)
      end
    end
    oldest = tickets.last

    get organisation_project_tickets_path(organisation, project, ticket_id: oldest.id)

    expect(response).to have_http_status(:ok),
                        "expected no redirect for a first-page ticket, got #{response.status} " \
                        "to #{response.location.inspect}"
  end

  it 'keeps the nested sort params on a legitimate page redirect' do
    ActsAsTenant.current_tenant = organisation

    tickets = Array.new(25) do |i|
      create(:ticket, project: project, organisation: organisation, creator: user,
                      created_at: (i + 1).minutes.ago)
    end
    # Under created_at ASC the newest ticket sits at position 25 -> page 2.
    newest = tickets.first

    get organisation_project_tickets_path(organisation, project),
        params: { ticket_id: newest.id, sort: { column: 'tickets.created_at', direction: 'asc' } }

    expect(response).to have_http_status(:redirect)
    expect(response.location).to include('page=2')
    expect(response.location).to include('sort%5Bcolumn%5D=tickets.created_at'),
                                 "sort params must survive the redirect, got #{response.location}"
  end
end
