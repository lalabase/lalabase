# frozen_string_literal: true

require 'rails_helper'

# GET /api/v1/time_sessions/open lists the person's own open hours. Which rows,
# and how much of each row's ticket, is decided by the same owners as
# everywhere else: the token's reach (organisations AND projects), the web's
# time-viewing rule (TimeSessions::ViewingScope) and TicketPolicy::Scope. A
# booking on a ticket the person may not read keeps its row and its minutes,
# and shows nothing of the ticket: no id, no number, no title.
#
# Fixtures are built under Prosopite.pause; each example sends ONE request, so
# the scan sees only that request.
RSpec.describe 'GET /api/v1/time_sessions/open: what the person may see', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  def build_fixtures(&)
    Prosopite.pause(&)
  ensure
    ActsAsTenant.current_tenant = nil
  end

  def member_of(org, admin: false, active: true)
    ActsAsTenant.with_tenant(org) do
      role = create(:role, organisation: org, title: admin ? 'account_admin' : 'Member')
      create(:membership, user: user, organisation: org, role: role, active: active)
    end
  end

  # A project of `org` where the person holds `tickets` access and, unless
  # told otherwise, the right to see their own time. access: false gives no
  # permission rows at all (an account admin needs none).
  def project_in(org, tickets: :read_write, view_own: true, access: true)
    ActsAsTenant.with_tenant(org) do
      project = create(:project, organisation: org)
      if access
        create(:project_permission, user: user, project: project, tickets_access: tickets)
        create(:time_session_permission, user: user, project: project, can_view_own: view_own, can_view_all: false)
      end
      project
    end
  end

  # An open booking of the person. With a title it is booked on a new ticket of
  # the same project; a number makes that ticket findable in the response text.
  def booking(project, title: nil, number: nil, minutes: 30, on: 1.day.ago, id: nil)
    ActsAsTenant.with_tenant(project.organisation) do
      ticket = title && create(:ticket, organisation: project.organisation, project: project, creator: user, title: title)
      ticket&.update_column(:number, number) if number
      TimeSession.create!({ id: id, project: project, organisation: project.organisation, creator: user,
                            ticket: ticket, occurred_on: on, duration: minutes,
                            description: "Own words #{minutes}", customer_description: "For the customer #{minutes}" }.compact)
    end
  end

  def token(**options)
    create(:personal_access_token, user: user, **options)
  end

  def get_open(pat, **query)
    get '/api/v1/time_sessions/open', params: query, headers: { 'Authorization' => "Bearer #{pat.token}" }
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body)
  end

  def row_for(body, session)
    body['data'].find { |row| row['id'] == session.id }
  end

  # Nothing of the ticket anywhere in the response text, not only a null field.
  # The number must be one no other part of the body can contain ("page":1).
  def expect_nothing_of(ticket)
    raise ArgumentError, 'give the ticket a distinctive number' if ticket.number < 100_000

    expect(response.body).not_to include(ticket.title)
    expect(response.body).not_to include(ticket.number.to_s)
    expect(response.body).not_to include(ticket.id)
  end

  def ticket_payload(ticket)
    { 'id' => ticket.id, 'number' => ticket.number, 'title' => ticket.title }
  end

  it 'keeps the row of a booking on a ticket the person may not read and shows nothing of the ticket' do
    session = build_fixtures do
      member_of(organisation)
      booking(project_in(organisation, tickets: :no_access), title: 'Hidden title one', number: 987_651)
    end
    pat = build_fixtures { token(organisations: [organisation]) }

    body = get_open(pat)

    expect(row_for(body, session)).to include('ticket' => nil)
    expect_nothing_of(session.ticket)
  end

  it 'hides the ticket once the read right is taken away after the booking' do
    project = nil
    session = build_fixtures do
      member_of(organisation)
      project = project_in(organisation, tickets: :read_write)
      booking(project, title: 'Hidden title two', number: 987_652)
    end
    pat = build_fixtures do
      ActsAsTenant.with_tenant(organisation) do
        ProjectPermission.find_by!(user: user, project: project).update!(tickets_access: :no_access)
      end
      token(organisations: [organisation])
    end

    body = get_open(pat)

    expect(row_for(body, session)).to include('ticket' => nil)
    expect_nothing_of(session.ticket)
  end

  it 'shows id, number and title of a ticket the person may read' do
    session = build_fixtures do
      member_of(organisation)
      booking(project_in(organisation, tickets: :read_only), title: 'Readable title')
    end
    pat = build_fixtures { token(organisations: [organisation]) }

    body = get_open(pat)

    expect(row_for(body, session)['ticket']).to eq(ticket_payload(session.ticket))
  end

  it 'shows the ticket to an account admin who holds no project permission' do
    session = build_fixtures do
      member_of(organisation, admin: true)
      booking(project_in(organisation, access: false), title: 'Admin reads this')
    end
    pat = build_fixtures { token(organisations: [organisation]) }

    body = get_open(pat)

    expect(row_for(body, session)['ticket']).to eq(ticket_payload(session.ticket))
  end

  it 'keeps the own row of an archived project with its project, but not its ticket' do
    project = nil
    session = build_fixtures do
      member_of(organisation)
      project = project_in(organisation, tickets: :read_write)
      booking(project, title: 'Archived ticket title', number: 987_655)
    end
    pat = build_fixtures do
      project.update_column(:archived_at, Time.current)
      token(organisations: [organisation])
    end

    body = get_open(pat)

    expect(row_for(body, session)).to include('ticket' => nil, 'project' => { 'id' => project.id, 'name' => project.name })
    expect_nothing_of(session.ticket)
  end

  it 'keeps the own words and minutes of a row whose ticket is hidden' do
    session = build_fixtures do
      member_of(organisation)
      booking(project_in(organisation, tickets: :no_access), title: 'Hidden title six', minutes: 75)
    end
    pat = build_fixtures { token(organisations: [organisation]) }

    body = get_open(pat)

    expect(row_for(body, session)).to include(
      'duration_minutes' => 75, 'description' => 'Own words 75', 'customer_description' => 'For the customer 75'
    )
  end

  it 'leaves out bookings in projects outside the token, in data and in meta' do
    inside, outside = build_fixtures do
      member_of(organisation)
      [booking(project_in(organisation), title: 'Inside title', minutes: 30),
       booking(project_in(organisation), title: 'Outside title', number: 987_657, minutes: 45)]
    end
    pat = build_fixtures { token(organisations: [organisation], project_scopes: { organisation => [inside.project] }) }

    body = get_open(pat)

    expect(body['data'].pluck('id')).to eq([inside.id])
    expect(body['meta']).to include('total' => 1, 'total_minutes' => 30)
    expect(response.body).not_to include(outside.project.name)
    expect_nothing_of(outside.ticket)
  end

  it 'leaves out the bookings of a project the person was removed from' do
    project = nil
    session = build_fixtures do
      member_of(organisation)
      project = project_in(organisation)
      booking(project, title: 'Removed project title', number: 987_658)
    end
    pat = build_fixtures do
      ActsAsTenant.with_tenant(organisation) do
        ProjectPermission.find_by!(user: user, project: project).update!(deleted_at: Time.current)
      end
      token(organisations: [organisation])
    end

    body = get_open(pat)

    expect(body['data']).to eq([])
    expect(body['meta']).to include('total' => 0, 'total_minutes' => 0)
    expect(response.body).not_to include(project.name)
    expect_nothing_of(session.ticket)
  end

  it 'leaves out the bookings of a project where the person may not see their own time' do
    session = build_fixtures do
      member_of(organisation)
      booking(project_in(organisation, view_own: false), title: 'No time view title', number: 987_659)
    end
    pat = build_fixtures { token(organisations: [organisation]) }

    body = get_open(pat)

    expect(body['data']).to eq([])
    expect(body['meta']).to include('total' => 0, 'total_minutes' => 0)
    expect_nothing_of(session.ticket)
  end

  it 'lets each organisation of an all-organisations token decide about its own tickets' do
    other = create(:organisation)
    readable_a, readable_b, hidden_b = build_fixtures do
      member_of(organisation)
      member_of(other)
      [booking(project_in(organisation), title: 'Readable in A', on: 1.day.ago),
       booking(project_in(other), title: 'Readable in B', on: 2.days.ago),
       booking(project_in(other, tickets: :no_access), title: 'Hidden in B', number: 987_660, on: 3.days.ago)]
    end
    pat = build_fixtures { token(all_organisations: true) }

    body = get_open(pat)

    expect(body['data'].pluck('id')).to eq([readable_a.id, readable_b.id, hidden_b.id])
    expect(row_for(body, readable_a)['ticket']).to eq(ticket_payload(readable_a.ticket))
    expect(row_for(body, readable_b)['ticket']).to eq(ticket_payload(readable_b.ticket))
    expect(row_for(body, hidden_b)['ticket']).to be_nil
    expect_nothing_of(hidden_b.ticket)
  end

  it 'counts in meta exactly the rows that data pages through' do
    pat = build_fixtures do
      member_of(organisation)
      inside = project_in(organisation)
      hidden_ticket = project_in(organisation, tickets: :no_access)
      outside = project_in(organisation)
      removed = project_in(organisation)
      booking(inside, title: 'Counted one', minutes: 10, on: 1.day.ago)
      booking(hidden_ticket, title: 'Counted two', minutes: 20, on: 2.days.ago)
      booking(outside, title: 'Outside the token', minutes: 40)
      booking(removed, title: 'Removed from it', minutes: 80)
      ActsAsTenant.with_tenant(organisation) do
        ProjectPermission.find_by!(user: user, project: removed).update!(deleted_at: Time.current)
      end
      token(organisations: [organisation], project_scopes: { organisation => [inside, hidden_ticket, removed] })
    end

    body = get_open(pat, per_page: 1)

    expect(body['data'].size).to eq(1)
    expect(body['meta']).to include('total' => 2, 'total_minutes' => 30, 'total_hours_decimal' => 0.5)
  end

  it 'applies the same rule on page two as on page one' do
    readable_two, hidden_two = build_fixtures do
      member_of(organisation)
      readable = project_in(organisation)
      hidden = project_in(organisation, tickets: :no_access)
      booking(readable, title: 'Page one readable', minutes: 10, on: 1.day.ago)
      booking(hidden, title: 'Page one hidden', minutes: 20, on: 2.days.ago)
      [booking(readable, title: 'Page two readable', minutes: 30, on: 3.days.ago),
       booking(hidden, title: 'Page two hidden', number: 987_662, minutes: 40, on: 4.days.ago)]
    end
    pat = build_fixtures { token(organisations: [organisation]) }

    body = get_open(pat, per_page: 2, page: 2)

    expect(body['data'].pluck('id')).to eq([readable_two.id, hidden_two.id])
    expect(row_for(body, readable_two)['ticket']).to eq(ticket_payload(readable_two.ticket))
    expect(row_for(body, hidden_two)['ticket']).to be_nil
    expect_nothing_of(hidden_two.ticket)
    expect(body['meta']).to include('page' => 2, 'total' => 4, 'total_minutes' => 100)
  end

  it 'reads several organisations and projects without a query per row' do
    readable = []
    hidden = []
    build_fixtures do
      organisations = [organisation, create(:organisation), create(:organisation)]
      organisations.each do |org|
        member_of(org)
        readable_project = project_in(org)
        hidden_project = project_in(org, tickets: :no_access)
        2.times { |i| readable << booking(readable_project, title: "Readable #{org.id} #{i}") }
        booking(readable_project, minutes: 5)
        2.times { |i| hidden << booking(hidden_project, title: "Hidden #{org.id} #{i}") }
      end
    end
    pat = build_fixtures { token(all_organisations: true) }

    body = get_open(pat)

    expect(body['data'].size).to eq(15)
    readable.each { |session| expect(row_for(body, session)['ticket']).to eq(ticket_payload(session.ticket)) }
    hidden.each { |session| expect(response.body).not_to include(session.ticket.title) }
  end

  it 'applies the time-viewing rule in every organisation, not only in the first' do
    other = create(:organisation)
    visible = build_fixtures do
      [organisation, other].map do |org|
        member_of(org)
        booking(project_in(org, view_own: false), title: "No time view in #{org.id}")
        booking(project_in(org))
      end
    end
    pat = build_fixtures { token(all_organisations: true) }

    body = get_open(pat)

    expect(body['data'].pluck('id')).to match_array(visible.map(&:id))
  end

  # Inserted out of order on purpose: with ties on occurred_on alone, the order
  # is whatever the sort happens to produce, and an insertion in id order
  # happened to produce the right page.
  it 'pages bookings of the same moment in a fixed order' do
    ids = (1..6).map { |n| format('00000000-0000-4000-8000-%012d', n) }
    build_fixtures do
      member_of(organisation)
      project = project_in(organisation)
      moment = 1.day.ago.change(usec: 0)
      [3, 6, 1, 5, 2, 4].each { |n| booking(project, id: ids[n - 1], on: moment) }
    end
    pat = build_fixtures { token(organisations: [organisation]) }

    body = get_open(pat, per_page: 2, page: 2)

    expect(body['data'].pluck('id')).to eq([ids[3], ids[2]])
  end

  # Until 2026-09-16 (a68838c2c) a booking moved to another project kept the
  # ticket of its old one; nothing rewrote those rows. The ticket's project,
  # not the booking's, then decides whether the token reaches it.
  it 'hides a ticket from a project outside the token even when the booking lies inside' do
    inside = nil
    session = build_fixtures do
      member_of(organisation)
      inside = project_in(organisation)
      moved_from = project_in(organisation)
      booked = booking(moved_from, title: 'Left behind in another project', number: 987_670)
      booked.update_column(:project_id, inside.id)
      booked
    end
    pat = build_fixtures { token(organisations: [organisation], project_scopes: { organisation => [inside] }) }

    body = get_open(pat)

    expect(row_for(body, session)).to include('ticket' => nil)
    expect_nothing_of(session.ticket)
  end

  # Codebase imports before 2026-09-16 left bookings that point at a ticket of
  # another organisation. Such a booking shows no ticket, also when a booking of
  # that other organisation on the same page may show it: the ticket belongs to
  # the row of its own organisation only.
  it 'shows no ticket of another organisation even when that ticket is readable on the same page' do
    other = create(:organisation)
    foreign, own = build_fixtures do
      member_of(organisation)
      member_of(other)
      own = booking(project_in(other), title: 'Readable in its own organisation', on: 1.day.ago)
      foreign = booking(project_in(organisation), on: 2.days.ago)
      foreign.update_column(:ticket_id, own.ticket_id)
      [foreign, own]
    end
    pat = build_fixtures { token(all_organisations: true) }

    body = get_open(pat)

    expect(row_for(body, own)['ticket']).to eq(ticket_payload(own.ticket))
    expect(row_for(body, foreign)).to include('ticket' => nil)
  end

  # The project's twin of the case above. Only an account admin reaches such a
  # row (ViewingScope hands everybody else the organisation's own project ids);
  # the admin of one organisation still learns nothing about a project of
  # another one from it.
  it 'shows no project of another organisation on a booking of this one' do
    other = create(:organisation)
    foreign_project = nil
    session = build_fixtures do
      member_of(organisation, admin: true)
      member_of(other)
      foreign_project = project_in(other)
      booked = booking(project_in(organisation, access: false))
      booked.update_column(:project_id, foreign_project.id)
      booked
    end
    pat = build_fixtures { token(organisations: [organisation]) }

    body = get_open(pat)

    expect(row_for(body, session)).to include('project' => nil)
    expect(response.body).not_to include(foreign_project.name)
    expect(response.body).not_to include(foreign_project.id)
  end
end
