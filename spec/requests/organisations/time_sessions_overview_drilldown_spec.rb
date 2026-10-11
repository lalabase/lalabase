# frozen_string_literal: true

require 'rails_helper'

# What: The one promise of the status table above the time list: the number a
#       reader clicks IS the sum the list then shows. For all three states, for
#       the total, and under a period that is NOT the table's default.
# Type: Request spec (mechanism, not declaration). It reads every number off the
#       rendered table, follows the link under it, and compares the list's own
#       total (@total_filtered_duration) with the minutes the cell printed.
# Why:  The table used to hand every cell `date_range: 'all'` while showing
#       all-time figures, so the two agreed by accident. With a period on the
#       table (S5, D3) they only agree if the cell carries it. The same walk
#       also catches the older half of the promise: the table counted sessions
#       the list would not show, because it asked no viewing scope.
RSpec.describe 'Time list overview drill-down', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:admin_role)   { create(:admin_role, organisation: organisation) }
  let(:user)         { create(:user) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
  end

  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Alpha') } }
  let(:other_project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Beta') } }

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  # "02:30" -> 150. Parsing the DISPLAYED value back is the point: it compares
  # what the reader saw with what the list answers, not two internal numbers.
  def minutes_from(text)
    hours, minutes = text.strip.split(':').map(&:to_i)
    (hours * 60) + minutes
  end

  # Every cell of the table that carries a number, as
  # [project_id, bucket ('billed' / ... / 'total'), minutes, href].
  def overview_cells
    doc = Nokogiri::HTML(response.body)
    doc.css('tr[data-overview-row]').flat_map do |row|
      row.css('td[data-overview-cell]').filter_map do |cell|
        link = cell.at_css('a')
        next if link.nil?

        [row['data-overview-row'], cell['data-overview-cell'], minutes_from(link.text), link['href']]
      end
    end
  end

  def get_overview(params = {})
    get organisation_time_sessions_path(organisation, view: 'overview', **params)
    expect(response).to have_http_status(:ok)
  end

  # The footnote under the table, by its own handle rather than by its words.
  def footnote_text
    Nokogiri::HTML(response.body).at_css('[data-overview-footnote]')&.text.to_s.strip
  end

  # Prosopite scans per EXAMPLE, and the walk below issues one request per
  # number on the table. The layout's identical queries ACROSS those requests
  # look like an N+1 and are none: it is the same page fetched again, which is
  # the whole point of the walk. Each request's own budget is guarded where that
  # page is guarded.
  def across_requests
    Prosopite.pause
    yield
  ensure
    Prosopite.resume
  end

  # May 2026: two bookings inside the month, one billed booking in January, one
  # billed booking in the PREVIOUS year, and a second project so the walk covers
  # more than one row. The 2025 booking is what makes "dieses Jahr" a different
  # question from "alles" -- without it that period would be vacuum-green.
  before do
    billed_group = create(:time_session_group, :billed, organisation: organisation)
    open_group   = create(:time_session_group, organisation: organisation)

    create(:time_session, project: project, organisation: organisation, creator: user, duration: 30,
                          occurred_on: Time.zone.local(2026, 5, 15, 9, 0))
    create(:time_session, project: project, organisation: organisation, creator: user, duration: 60,
                          time_session_group: open_group, occurred_on: Time.zone.local(2026, 5, 16, 9, 0))
    create(:time_session, project: project, organisation: organisation, creator: user, duration: 120,
                          billed: true, billed_at: Time.zone.local(2026, 1, 10),
                          time_session_group: billed_group, occurred_on: Time.zone.local(2026, 1, 9, 9, 0))
    create(:time_session, project: project, organisation: organisation, creator: user, duration: 90,
                          billed: true, billed_at: Time.zone.local(2025, 11, 4),
                          time_session_group: billed_group, occurred_on: Time.zone.local(2025, 11, 3, 9, 0))
    create(:time_session, project: other_project, organisation: organisation, creator: user, duration: 45,
                          billed: true, billed_at: Time.zone.local(2026, 5, 4),
                          time_session_group: billed_group, occurred_on: Time.zone.local(2026, 5, 3, 9, 0))
  end

  # THE non-negotiable spec of S5. It is a loop on purpose: hand-picking one
  # cell would leave the other five untested, and the period is exactly the kind
  # of mistake that shows up in one column only.
  %w[all this_month year].each do |period|
    it "every number under period=#{period} equals the sum the list then shows" do
      travel_to Time.zone.local(2026, 5, 20, 12, 0) do
        across_requests do
          get_overview(date_range: period)
          cells = overview_cells
          expect(cells).not_to be_empty, "no numbers on the table under #{period}"

          cells.each do |project_id, bucket, minutes, href|
            get href
            expect(response).to have_http_status(:ok)
            expect(assigns(:total_filtered_duration)).to eq(minutes),
                                                         "#{bucket} of project #{project_id} showed #{minutes} " \
                                                         "but the list answered #{assigns(:total_filtered_duration)}"
          end
        end
      end
    end
  end

  it 'covers all three states and the total, not just the ones that happen to be filled' do
    travel_to Time.zone.local(2026, 5, 20, 12, 0) do
      get_overview(date_range: 'all')

      expect(overview_cells.map { |_id, bucket, _m, _h| bucket }.uniq)
        .to match_array(TimeSession::BILLING_OVERVIEW_COLUMNS)
    end
  end

  # The counter-half that makes the equality above mean something: the period
  # really does change the figures, and each of the three the loop walks is a
  # DIFFERENT question. If these ever come out equal, the period is not reaching
  # the table and the loop above is vacuum-green.
  it 'the three periods the loop walks give three different totals' do
    travel_to Time.zone.local(2026, 5, 20, 12, 0) do
      across_requests do
        totals = %w[all year this_month].to_h do |period|
          get_overview(date_range: period)
          [period, overview_cells.sum { |_id, bucket, minutes, _h| bucket == TimeSession::BILLING_OVERVIEW_TOTAL ? minutes : 0 }]
        end

        expect(totals).to eq('all' => 345, 'year' => 255, 'this_month' => 135)
      end
    end
  end

  # The RETURN leg. The outward leg carries the period into the list; the way
  # back has to bring it home, or the click that is supposed to return the
  # reader to their table undoes the choice they made on it.
  it 'keeps the period on the way back to the overview' do
    travel_to Time.zone.local(2026, 5, 20, 12, 0) do
      across_requests do
        get_overview(date_range: 'year')
        _project_id, _bucket, _minutes, href = overview_cells.first
        get href

        back = Nokogiri::HTML(response.body).at_css('[data-overview-trail] a')
        expect(back).to be_present, 'no way back from the drill-down'
        expect(back['href']).to include('view=overview')
        expect(back['href']).to include('date_range=year'), "the way back dropped the period: #{back['href']}"
      end
    end
  end

  # `custom` is the list's alone: its window comes from two date fields the
  # table does not have. Typing a bound and then walking back must land on the
  # table's own default, not on a period it cannot show.
  it 'sends a hand-typed range back as the table default' do
    travel_to Time.zone.local(2026, 5, 20, 12, 0) do
      get organisation_time_sessions_path(organisation, from: 'overview', project_id_filter: project.id,
                                                        date_range: 'year', start_date: '2026-01-01',
                                                        end_date: '2026-01-31')
      expect(response).to have_http_status(:ok)

      back = Nokogiri::HTML(response.body).at_css('[data-overview-trail] a')
      expect(back['href']).to include("date_range=#{TimeSessions::ListPeriod::TABLE_DEFAULT}")
    end
  end

  it 'carries the chosen period into the address, not a neutral "alles"' do
    travel_to Time.zone.local(2026, 5, 20, 12, 0) do
      get_overview(date_range: 'this_month')

      overview_cells.each do |_id, bucket, _minutes, href|
        expect(href).to include('date_range=this_month'), "#{bucket} dropped the period"
        expect(href).to include('from=overview')
      end
    end
  end

  # An unknown period is not an empty table and not a 500: the table falls back
  # to its own default. Before S5 the value travelled on untouched.
  it 'falls back to "alles" for a period it does not know' do
    travel_to Time.zone.local(2026, 5, 20, 12, 0) do
      get_overview(date_range: 'nonsense')

      expect(assigns(:table_period)).to eq('all')
      expect(overview_cells.sum { |_id, bucket, minutes, _h| bucket == TimeSession::BILLING_OVERVIEW_TOTAL ? minutes : 0 }).to eq(345)
    end
  end

  it 'does not offer the list-only "custom" period, whose bounds it has no fields for' do
    travel_to Time.zone.local(2026, 5, 20, 12, 0) do
      get_overview(date_range: 'custom')

      expect(assigns(:table_period)).to eq('all')
    end
  end

  it 'offers the eight presets above the table, with the chosen one selected and custom absent' do
    travel_to Time.zone.local(2026, 5, 20, 12, 0) do
      get_overview(date_range: 'this_month')

      select = Nokogiri::HTML(response.body).at_css('select[name="date_range"]')
      expect(select).to be_present, 'no period control above the table'
      expect(select.css('option').map { |o| o['value'] }).to eq(TimeSessions::ListPeriod::KEYS)
      expect(select.at_css('option[selected]')['value']).to eq('this_month')
      # The control has to carry the view along, or the answer is the list.
      expect(response.body).to include('name="view" id="view" value="overview"')
    end
  end

  # The oracle here is the DIFFERENCE between two periods, not a second
  # I18n.t. An expectation built from the same entry the view renders follows
  # the text wherever it goes: put "Aktueller Status aller Sessions" back into
  # both locales, the unused period: argument is silently dropped, and page and
  # expectation change together. Two periods cannot both be one sentence.
  it 'names the chosen period in the footnote instead of claiming all time' do
    travel_to Time.zone.local(2026, 5, 20, 12, 0) do
      across_requests do
        get_overview(date_range: 'this_month')
        month = footnote_text
        get_overview(date_range: 'year')
        year = footnote_text

        expect(month).not_to eq(year), "the footnote reads the same under two periods: #{month.inspect}"
        expect(month).to include(TimeSessions::ListPeriod.label('this_month'))
        expect(year).to include(TimeSessions::ListPeriod.label('year'))
      end
    end
  end

  # The row is only trustworthy while its total IS the sum of its cells, which
  # is what ONE period for the whole table buys (D3). Read off the RENDERED
  # table, because in the service the total is a derived expression and any
  # assertion there restates its own definition.
  it 'prints a total that is the sum of the three state cells, under a narrow period' do
    travel_to Time.zone.local(2026, 5, 20, 12, 0) do
      get_overview(date_range: 'this_month')

      by_row = overview_cells.group_by { |project_id, _bucket, _minutes, _href| project_id }
      expect(by_row).not_to be_empty

      by_row.each do |project_id, cells|
        printed = cells.to_h { |_id, bucket, minutes, _href| [bucket, minutes] }
        buckets = TimeSession::BILLING_STATUS_FILTERS.sum { |bucket| printed.fetch(bucket, 0) }

        expect(printed[TimeSession::BILLING_OVERVIEW_TOTAL]).to eq(buckets), "row #{project_id}: total #{printed[TimeSession::BILLING_OVERVIEW_TOTAL]} vs cells #{buckets}"
      end
    end
  end

  # The walk above signs in an account admin, and for an admin
  # ViewingScope#apply returns the relation untouched (viewing_scope.rb) and
  # #projects is every project of the organisation. So it proves the PERIOD half
  # of the promise and nothing at all about the viewing scope: drop
  # `viewing_scope.apply` from TimeSessionStatisticsService#scoped_sessions and
  # every example above stays green.
  #
  # Here the two sums really are computed through two different call sites of
  # the same rule -- the table through ViewingScope#apply, the list through
  # TimeSessionPolicy::Scope -- which is the only place they can disagree. The
  # overview is open to Finance roles (TimeSessionStatisticsPolicy), whose tier
  # still comes from the permission rows, so this reader is not a hypothetical.
  context 'as a Finance reader who may see only their own hours' do
    let(:finance_role) { create(:role, organisation: organisation, title: 'Finance') }
    let(:reader)       { create(:user) }
    let(:colleague)    { create(:user) }

    before do
      create(:membership, user: reader, organisation: organisation, role: finance_role, active: true)
      create(:membership, user: colleague, organisation: organisation, role: finance_role, active: true)
      create(:time_session_permission, user: reader, project: project, can_view_own: true, can_view_all: false)

      create(:time_session, project: project, organisation: organisation, creator: reader, duration: 20,
                            occurred_on: Time.zone.local(2026, 5, 12, 9, 0))
      create(:time_session, project: project, organisation: organisation, creator: colleague, duration: 300,
                            occurred_on: Time.zone.local(2026, 5, 13, 9, 0))
      sign_in reader
    end

    %w[all this_month].each do |period|
      it "every number under period=#{period} equals the sum the list then shows" do
        travel_to Time.zone.local(2026, 5, 20, 12, 0) do
          across_requests do
            get_overview(date_range: period)
            cells = overview_cells
            expect(cells).not_to be_empty, "no numbers on the table under #{period}"

            cells.each do |project_id, bucket, minutes, href|
              get href
              expect(response).to have_http_status(:ok)
              expect(assigns(:total_filtered_duration)).to eq(minutes),
                                                           "#{bucket} of project #{project_id} showed #{minutes} " \
                                                           "but the list answered #{assigns(:total_filtered_duration)}"
            end
          end
        end
      end
    end

    # Mutation probe: drop viewing_scope.apply from #scoped_sessions and the
    # 300 minutes of the colleague appear here; drop the ViewingScope from
    # #filtered_projects and Beta becomes a row.
    it 'counts neither the colleague nor a project it holds no rights in' do
      travel_to Time.zone.local(2026, 5, 20, 12, 0) do
        other_project
        get_overview(date_range: 'all')

        expect(overview_cells.map { |project_id, _b, _m, _h| project_id }.uniq).to eq([project.id])
        expect(overview_cells.sum { |_id, bucket, minutes, _h| bucket == TimeSession::BILLING_OVERVIEW_TOTAL ? minutes : 0 }).to eq(20)
      end
    end
  end
end
