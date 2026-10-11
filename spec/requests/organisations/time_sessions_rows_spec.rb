# frozen_string_literal: true

require 'rails_helper'

# What: the time list paginates over ROWS (one subject in one project in one
#       month), not over single bookings.
# Type: Request spec.
# Why:  S2 of doc/projektzeiten_tabelle_plan.md. Every number the redesigned
#       table shows is an aggregate, so a page that cuts a month in half prints
#       a fragment under that month's name. The rows also have to come out of
#       Postgres in the order the app claims, exactly once each.
RSpec.describe 'Organisations::TimeSessions rows', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:admin) { create(:user) }

  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  let(:august) { Time.utc(2026, 8, 15, 10, 0) }
  let(:july)   { Time.utc(2026, 7, 15, 10, 0) }

  before do
    ActsAsTenant.current_tenant = organisation
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
    end
    Prosopite.pause
    sign_in admin
  end

  after { Prosopite.resume }

  def book(minutes, on: august, ticket: nil, meeting: nil, in_project: project, description: 'Zeile')
    ActsAsTenant.with_tenant(organisation) do
      create(:time_session, organisation: organisation, project: in_project, creator: admin,
                            duration: minutes, occurred_on: on, ticket: ticket, meeting: meeting,
                            description: description)
    end
  end

  def ticket_with(title)
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: title) }
  end

  def get_list(**params)
    get organisation_time_sessions_path(organisation, date_range: 'all', **params)
  end

  def rows
    assigns(:list_months).flat_map { |month| month[:rows] }
  end

  describe 'the base both queries start from' do
    # Failing-first without rows_base: the search path carries .distinct and
    # joins, a GROUP BY over that is a Postgres error and a .sum over it is
    # SUM(DISTINCT), which folds two equal durations into one.
    it 'survives a search and still adds two equal durations to their true sum' do
      ticket = ticket_with('Suchbarer Bezug')
      book(60, ticket: ticket, description: 'Findewort eins')
      book(60, ticket: ticket, description: 'Findewort zwei')

      get_list(search: 'Findewort')

      expect(response).to have_http_status(:ok)
      expect(rows.sum { |row| row[:minutes] }).to eq(120)
      expect(assigns(:list_months).sum { |month| month[:sum_minutes] }).to eq(120)
    end
  end

  describe 'a page of rows' do
    # items is passed on purpose: the per-page number comes from the user's own
    # preference (20) before it comes from the controller default, and this
    # example is about rows, not about that preference.
    it 'counts rows, not bookings, and leaves the eleventh on page two' do
      11.times { |i| book(30, ticket: ticket_with(format('Ticket %02d', i))) }

      get_list(items: 10)
      expect(assigns(:pagy).count).to eq(11)
      expect(assigns(:pagy).pages).to eq(2)
      expect(rows.size).to eq(10)

      get_list(items: 10, page: 2)
      expect(rows.size).to eq(1)
    end

    it 'keeps a month whole rather than splitting it across pages by booking count' do
      ticket = ticket_with('Ein Bezug, viele Buchungen')
      15.times { book(10, ticket: ticket) }

      get_list

      expect(assigns(:pagy).count).to eq(1)
      expect(rows.size).to eq(1)
      expect(rows.first[:minutes]).to eq(150)
    end

    it 'caps the page size for this list, whatever the address asks for' do
      3.times { |i| book(30, ticket: ticket_with("T#{i}")) }

      get_list(items: 200)

      expect(assigns(:pagy).limit).to eq(50)
    end

    it 'asks the database for the number of rows instead of loading every group' do
      3.times { |i| book(30, ticket: ticket_with("T#{i}")) }

      statements = capture_sql { get_list }
      # Narrow to THIS count: the layout's notification bell runs one of its own.
      counts = statements.grep(/SELECT COUNT\(\*\) FROM \(SELECT "time_sessions"/)

      expect(counts.size).to eq(1)
    end
  end

  describe 'the order of the rows' do
    # Postgres under collation C and Ruby's <=> after downcase have to agree, or
    # the same list is sorted one way in the database and another in a spec.
    it 'matches TimeSession.subject_sort_key, with "ohne Bezug" trailing' do
      %w[Zebra aerger arger Bergen].each { |title| book(30, ticket: ticket_with(title)) }
      book(30) # ohne Bezug

      get_list

      # Written out rather than computed: a test that re-derives the rule it
      # checks passes for a wrong rule too. lower() has to come first, because
      # byte order alone puts every capital ahead of every lowercase and "Zebra"
      # would lead. Deliberately free of ties, so nothing here depends on the
      # fixed tail; the example below covers that.
      expect(rows.map { |row| row[:subject]&.title })
        .to eq(['aerger', 'arger', 'Bergen', 'Zebra', nil])
    end

    it 'gives every row exactly once across two pages, even with equal titles' do
      12.times { book(30, ticket: ticket_with('Gleicher Titel')) }

      get_list(items: 10)
      first_page = rows.map { |row| row[:key] }
      get_list(items: 10, page: 2)
      second_page = rows.map { |row| row[:key] }

      expect(first_page.size).to eq(10)
      expect(second_page.size).to eq(2)
      expect((first_page + second_page).uniq.size).to eq(12)
    end

    # A tie cannot be provoked from a spec: with a handful of rows Postgres
    # happens to return the same order twice, and the example above stays green
    # even with the tail removed (probed, 30.08.2026). What can be pinned is that
    # the tail is IN the query, which is what keeps the order deterministic when
    # a different plan (a parallel scan, another index) picks a different one.
    it 'orders by the key columns after the title, so a tie cannot drift between pages' do
      book(30, ticket: ticket_with('Egal'))

      keys_query = capture_sql { get_list }.grep(/GROUP BY/).grep(/ORDER BY/).first

      expect(keys_query).to include(
        '"time_sessions"."project_id" ASC, "time_sessions"."ticket_id" ASC, "time_sessions"."meeting_id" ASC'
      )
    end

    it 'sorts months newest first' do
      ticket = ticket_with('Ueber zwei Monate')
      book(30, on: august, ticket: ticket)
      book(60, on: july, ticket: ticket)

      get_list

      expect(assigns(:list_months).map { |month| month[:month] })
        .to eq([Date.new(2026, 8, 1), Date.new(2026, 7, 1)])
    end
  end

  describe '"ohne Bezug"' do
    it 'stays one row per project, so it never sums two projects into one figure' do
      other = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      book(60)
      book(30, in_project: other)

      get_list

      subjectless = rows.select { |row| row[:subject].nil? }
      expect(subjectless.size).to eq(2)
      expect(subjectless.map { |row| row[:minutes] }).to contain_exactly(60, 30)
    end
  end

  describe '"x von y ausgeblendet"' do
    it 'counts against the subject and the month, not against the current filter' do
      ticket = ticket_with('Teilweise sichtbar')
      book(60, ticket: ticket, description: 'Findewort')
      book(90, ticket: ticket, description: 'unsichtbar fuer die Suche')

      get_list(search: 'Findewort')

      row = rows.first
      expect(row[:minutes]).to eq(60)
      expect(row[:total_minutes]).to eq(150)
      expect(row[:hidden_minutes]).to eq(90)
    end
  end

  describe 'the second build site' do
    it 'builds the same rows after saving as it does on load' do
      ticket = ticket_with('Nach dem Speichern')
      book(60, ticket: ticket)

      post organisation_project_time_sessions_path(organisation, project),
           params: { context: 'index_page',
                     time_session: { duration_string: '01:00', occurred_on: august, ticket_id: ticket.id,
                                     description: 'Frisch gebucht' } },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      expect(assigns(:list_months)).to be_present
      expect(assigns(:list_months).first[:rows].first[:key].size).to eq(4)
    end
  end

  describe 'a bookmarked sort parameter' do
    # The list has no sortable columns any more: its order is fixed (months
    # newest first, then the subject alphabetically). An address somebody
    # bookmarked before still carries sort[column], and it used to wrap the query
    # in the DISTINCT FROM-subquery of the Sortable concern, which on the
    # smart-folder path answered with a 500.
    it 'is ignored rather than answered with a 500, smart folder included' do
      folder = ActsAsTenant.with_tenant(organisation) do
        f = create(:smart_folder, organisation: organisation, user: admin,
                                  project: nil, target_object_type: 'TimeSession')
        group = create(:smart_folder_rule_group, smart_folder: f, position: 1)
        create(:smart_folder_rule, smart_folder_rule_group: group, position: 1,
                                   field: 'created_at', operator: 'in_the_last_days', value: '30')
        f
      end
      book(30, ticket: ticket_with('Sortierbar'))

      get_list(sort: { column: 'tickets.title', direction: 'asc' })
      expect(response).to have_http_status(:ok)

      get_list(smart_folder_id: folder.id, sort: { column: 'tickets.title', direction: 'asc' })
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'inside a smart folder' do
    # "06:40 von 13:40" has to keep meaning "of this subject in this month". The
    # denominator comes from visible_time_sessions_scope, which is built from the
    # project or the organisation and never from the folder's results -- inside a
    # folder, "von y" would otherwise quietly mean "of this folder".
    it 'still counts the hidden minutes against the subject and the month' do
      folder = ActsAsTenant.with_tenant(organisation) do
        f = create(:smart_folder, organisation: organisation, user: admin,
                                  project: nil, target_object_type: 'TimeSession')
        group = create(:smart_folder_rule_group, smart_folder: f, position: 1)
        create(:smart_folder_rule, smart_folder_rule_group: group, position: 1,
                                   field: 'duration', operator: 'greater_than', value: '50')
        f
      end
      ticket = ticket_with('Halb im Ordner')
      book(60, ticket: ticket)
      book(30, ticket: ticket)

      get_list(smart_folder_id: folder.id)

      row = rows.first
      expect(row[:minutes]).to eq(60)
      expect(row[:total_minutes]).to eq(90)
      expect(row[:hidden_minutes]).to eq(30)
    end
  end

  describe 'the paging links' do
    # Asserted on the href, because page 1 looks right either way.
    #
    # The plan expected a defect here (ticket_id sits in
    # ApplicationHelper::PAGY_URL_DROP_PARAMS, so a drill-down would lose its
    # filter on page 2). It does not apply to this list: the compact nav builds
    # its links in PaginationHelper#pagination_page_url, which keeps the whole
    # query except `page`, and pagy_url_for never sees them. Measured 30.08.2026,
    # by putting the parameter back on the drop list and watching this example
    # stay green. The full nav that does use pagy_url_for is rendered by the
    # activities and smart-folder lists, neither of which has a ticket_id filter.
    # So this is a guard on what is, not a fix.
    it 'carry every filter the address arrived with' do
      ticket = ticket_with('Gefiltert')
      # Eleven MONTHS, not eleven bookings: a ticket_id filter leaves one row per
      # month, and one row is one page.
      (1..11).each { |month| book(30, on: Time.utc(2026, month, 15, 10, 0), ticket: ticket, description: "Findewort #{month}") }

      get_list(items: 10, ticket_id: ticket.id, search: 'Findewort',
               status_filters: TimeSession::BILLING_STATUS_FILTERS)

      hrefs = Nokogiri::HTML(response.body).css('a[href*="page=2"]').map { |a| a['href'] }

      expect(hrefs).not_to be_empty
      expect(hrefs.first).to include("ticket_id=#{ticket.id}")
      expect(hrefs.first).to include('search=Findewort')
      expect(hrefs.first).to include('status_filters')
    end
  end

  describe 'the query budget' do
    it 'does not grow with the bookings inside a row' do
      few = ticket_with('Wenige')
      3.times { book(10, ticket: few) }
      small = capture_sql { get_list }.size

      many = ticket_with('Viele')
      60.times { book(10, ticket: many) }
      large = capture_sql { get_list }.size

      expect(large).to be <= small + 2
    end

    # Exact, not a budget: the queries are a fixed set (count, keys, bookings,
    # the preloads, the hidden totals), so more ROWS must cost nothing extra.
    # It did cost two each until ROW_INCLUDES also preloaded the subject's
    # project and its organisation, which the row needs for the link and for the
    # area permission.
    it 'does not grow with the number of rows either' do
      3.times { |i| book(30, ticket: ticket_with("Drei #{i}")) }
      three = capture_sql { get_list }.size

      2.times { |i| book(30, ticket: ticket_with("Fuenf #{i}")) }
      five = capture_sql { get_list }.size

      expect(five).to eq(three)
    end
  end
end
