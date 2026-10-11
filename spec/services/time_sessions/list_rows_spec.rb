# frozen_string_literal: true

require 'rails_helper'

# What: TimeSessions::ListRows, the three levels of the Projektzeiten table:
#       month > one subject in that month > the single bookings under it.
# Type: Service spec.
# Why:  S1 of doc/projektzeiten_tabelle_plan.md. The numbers ARE the redesign:
#       a month sum, a share bar, and the sentence "06:40 von 13:40 · 07:00
#       ausgeblendet". Every one of them is a way to be quietly wrong, and the
#       last one can hand a colleague's hours to somebody who may not see them.
RSpec.describe TimeSessions::ListRows do
  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:user)         { create(:user) }
  let(:colleague)    { create(:user) }

  let(:august) { Time.utc(2026, 8, 15, 10, 0) }
  let(:july)   { Time.utc(2026, 7, 15, 10, 0) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
    create(:membership, user: colleague, organisation: organisation)
  end

  after { ActsAsTenant.current_tenant = nil }

  def book(minutes, on:, ticket: nil, meeting: nil, in_project: project, creator: user, group: nil, billed: false)
    create(:time_session, project: in_project, organisation: organisation, creator: creator,
                          duration: minutes, occurred_on: on, ticket: ticket, meeting: meeting,
                          time_session_group: group, billed: billed)
  end

  # The page exactly as the controller will hand it over (S2): the month key is
  # the one the DATABASE computed, never one Ruby recomputed, and the
  # associations are preloaded because the row asks for group names and titles.
  def page(relation = TimeSession.all)
    relation.preload(:ticket, :meeting, :project, :time_session_group)
            .select('time_sessions.*', "#{described_class.month_key_sql} AS month_key")
            .to_a
  end

  def keys_of(sessions)
    sessions.map { |s| [s.project_id, s.ticket_id, s.meeting_id, s.month_key] }.uniq
  end

  def build(sessions = page, visible_scope: TimeSession.all)
    described_class.call(visible_scope: visible_scope, sessions: sessions, page_keys: keys_of(sessions))
  end

  def rows_of(months)
    months.flat_map { |m| m[:rows] }
  end

  describe 'the row key' do
    it 'splits one ticket into one row per month' do
      ticket = create(:ticket, project: project)
      book(60, on: august, ticket: ticket)
      book(90, on: july, ticket: ticket)

      months = build
      expect(months.map { |m| m[:month] }).to eq([Date.new(2026, 8, 1), Date.new(2026, 7, 1)])
      expect(rows_of(months).map { |r| r[:minutes] }).to eq([60, 90])
    end

    it 'keeps "ohne Bezug" apart per project, so one row never sums two projects' do
      other_project = create(:project, organisation: organisation)
      book(60, on: august)
      book(30, on: august, in_project: other_project)

      rows = rows_of(build)

      expect(rows.size).to eq(2)
      expect(rows.map { |r| r[:minutes] }).to contain_exactly(60, 30)
      expect(rows.map { |r| r[:project].id }).to contain_exactly(project.id, other_project.id)
      expect(rows.map { |r| r[:subject] }).to all(be_nil)
    end

    it 'tells a ticket from a meeting booked in the same month' do
      ticket = create(:ticket, project: project)
      meeting = create(:meeting, project: project, organisation: organisation)
      book(60, on: august, ticket: ticket)
      book(30, on: august, meeting: meeting)

      expect(rows_of(build).map { |r| r[:subject] }).to contain_exactly(ticket, meeting)
    end
  end

  describe 'the month boundary' do
    # The whole reason the month key comes from SQL: computed in Ruby with a
    # zone that is not the database's, a booking lands in the wrong month, and
    # nothing says so.
    it 'follows Time.zone, not UTC' do
      Time.use_zone('Europe/Berlin') do
        session = book(60, on: Time.utc(2026, 1, 31, 23, 30)) # 00:30 on 1 February in Berlin
        months = build

        expect(months.first[:month]).to eq(Date.new(2026, 2, 1))
        expect(months.first[:rows].first[:key].last).to eq(page.find { |s| s.id == session.id }.month_key)
      end
    end

    it 'puts a booking near the end of a month into exactly one month' do
      Time.use_zone('Europe/Berlin') do
        book(60, on: Time.utc(2026, 10, 31, 23, 30)) # after the DST change, 00:30 on 1 November

        months = build
        expect(months.size).to eq(1)
        expect(months.first[:month]).to eq(Date.new(2026, 11, 1))
      end
    end
  end

  describe 'the buckets behind the bar' do
    it 'names them exactly as the model does' do
      book(60, on: august)

      expect(rows_of(build).first[:shares].keys).to match_array(TimeSession::BILLING_STATUS_FILTERS)
    end

    it 'counts a billed session as billed even though it still hangs in a group' do
      group = create(:time_session_group, organisation: organisation)
      book(60, on: august, group: group, billed: true)

      shares = rows_of(build).first[:shares]
      expect(shares['billed']).to eq(60)
      expect(shares['in_billing']).to eq(0)
    end

    it 'adds up several bookings of the same bucket' do
      book(10, on: august)
      book(20, on: august)
      book(30, on: august)

      expect(rows_of(build).first[:shares]['without_billing']).to eq(60)
    end
  end

  describe 'the word and the number' do
    let(:group) { create(:time_session_group, organisation: organisation) }
    let(:ticket) { create(:ticket, project: project) }

    def state_and_percent
      row = rows_of(build).first
      [row[:state], row[:percent]]
    end

    it 'says the bucket when only one is filled, and offers no number to show' do
      book(60, on: august, ticket: ticket)
      expect(state_and_percent).to eq([:without_billing, nil])
    end

    it 'says billed when everything is billed' do
      book(60, on: august, ticket: ticket, group: group, billed: true)
      expect(state_and_percent).to eq([:billed, 100])
    end

    # n-1 / n / n+1 around the rounding, because the word must come from the
    # buckets and not from the number: 1 of 1000 minutes is still mixed.
    it 'rounds 1 of 1000 billed minutes to 0 per cent and still says mixed' do
      book(1, on: august, ticket: ticket, group: group, billed: true)
      book(999, on: august, ticket: ticket)
      expect(state_and_percent).to eq([:mixed, 0])
    end

    it 'rounds 500 of 1000 to 50 per cent' do
      book(500, on: august, ticket: ticket, group: group, billed: true)
      book(500, on: august, ticket: ticket)
      expect(state_and_percent).to eq([:mixed, 50])
    end

    it 'rounds 999 of 1000 to 100 per cent and still says mixed' do
      book(999, on: august, ticket: ticket, group: group, billed: true)
      book(1, on: august, ticket: ticket)
      expect(state_and_percent).to eq([:mixed, 100])
    end

    it 'has no number when nothing is billed, mixed or not' do
      book(60, on: august, ticket: ticket, group: group)
      book(60, on: august, ticket: ticket)
      expect(state_and_percent).to eq([:mixed, nil])
    end
  end

  describe 'the hidden minutes behind "x von y"' do
    let(:ticket) { create(:ticket, project: project) }

    def visible_scope_for(viewer)
      TimeSessions::ViewingScope.for_organisation(user: viewer, organisation: organisation).apply(TimeSession.all)
    end

    it 'counts what the current filter hides' do
      book(60, on: august, ticket: ticket)
      book(90, on: august, ticket: ticket, billed: true)

      unbilled_page = page(TimeSession.where(billed: false))
      row = rows_of(build(unbilled_page)).first

      expect(row[:minutes]).to eq(60)
      expect(row[:total_minutes]).to eq(150)
      expect(row[:hidden_minutes]).to eq(90)
    end

    it 'says nothing is hidden when the filter hides nothing' do
      book(60, on: august, ticket: ticket)

      row = rows_of(build).first
      expect(row[:hidden_minutes]).to eq(0)
      expect(row[:total_minutes]).to eq(60)
    end

    # THE example this object exists for. Without the narrowed scope the sentence
    # "60 von 120" tells a can_view_own user exactly how much the colleague
    # booked on that ticket, which no screen is allowed to say.
    it 'never counts a colleague\'s minutes for someone who may only see their own' do
      create(:time_session_permission, user: user, project: project, can_view_own: true, can_view_all: false)
      book(60, on: august, ticket: ticket)
      book(60, on: august, ticket: ticket, creator: colleague)

      own_page = page(visible_scope_for(user))
      row = rows_of(build(own_page, visible_scope: visible_scope_for(user))).first

      expect(row[:minutes]).to eq(60)
      expect(row[:total_minutes]).to eq(60)
      expect(row[:hidden_minutes]).to eq(0)
    end

    # n-1 at the bottom edge: a total BELOW the visible sum would mean the page
    # shows something the unfiltered scope does not. Mutation: drop the max() and
    # the screen reads "-01:00 ausgeblendet".
    it 'never reports a negative amount as hidden' do
      book(60, on: august, ticket: ticket)
      book(60, on: august, ticket: ticket, creator: colleague)

      row = rows_of(build(page, visible_scope: TimeSession.where(creator: user))).first

      expect(row[:minutes]).to eq(120)
      expect(row[:total_minutes]).to eq(120)
      expect(row[:hidden_minutes]).to eq(0)
    end

    # Mutation: remove the IS NULL branch from the subject clause. With a ticket
    # row beside it the subject-less row then drops out of the total query, its
    # key is missing, and "x von y" quietly falls back to "y = x".
    it 'gives a subject-less row its own denominator next to a ticket row' do
      book(60, on: august, ticket: ticket)
      book(40, on: august)
      book(90, on: august, billed: true)

      rows = rows_of(build(page(TimeSession.where(billed: false))))
      subjectless = rows.find { |row| row[:subject].nil? }

      expect(subjectless[:minutes]).to eq(40)
      expect(subjectless[:total_minutes]).to eq(130)
      expect(subjectless[:hidden_minutes]).to eq(90)
    end

    it 'keeps that promise per project when the tiers differ across an organisation' do
      all_project = create(:project, organisation: organisation)
      all_ticket = create(:ticket, project: all_project)
      create(:time_session_permission, user: user, project: project, can_view_own: true, can_view_all: false)
      create(:time_session_permission, user: user, project: all_project, can_view_all: true)

      book(60, on: august, ticket: ticket)
      book(60, on: august, ticket: ticket, creator: colleague)
      book(30, on: august, ticket: all_ticket, in_project: all_project)
      book(45, on: august, ticket: all_ticket, in_project: all_project, creator: colleague)

      scope = visible_scope_for(user)
      rows = rows_of(build(page(scope), visible_scope: scope))
      own_row = rows.find { |r| r[:subject] == ticket }
      all_row = rows.find { |r| r[:subject] == all_ticket }

      expect(own_row[:total_minutes]).to eq(60)
      expect(all_row[:total_minutes]).to eq(75)
    end
  end

  describe 'the sums' do
    it 'makes a month sum that equals the rows under it' do
      ticket = create(:ticket, project: project)
      book(60, on: august, ticket: ticket)
      book(30, on: august)
      book(90, on: july)

      months = build
      august_month = months.find { |m| m[:month] == Date.new(2026, 8, 1) }

      expect(august_month[:sum_minutes]).to eq(90)
      expect(august_month[:sum_minutes]).to eq(august_month[:rows].sum { |r| r[:minutes] })
    end
  end

  describe 'the contract with its caller' do
    # Mutation: delete ensure_month_key! and this turns into a NoMethodError on
    # nil somewhere deeper, which is a worse thing to read at three in the
    # morning than the sentence the guard prints.
    it 'refuses sessions that were loaded without the month key' do
      book(60, on: august)

      expect { described_class.call(visible_scope: TimeSession.all, sessions: TimeSession.all.to_a, page_keys: [[project.id, nil, nil, Date.new(2026, 8, 1)]]) }
        .to raise_error(ArgumentError, /month_key/)
    end

    # Mutation: turn the `||` in the early return into `&&`. Keys without their
    # sessions is what the coarse narrowing can hand back, and the object then
    # walks into `@sessions.first.has_attribute?` on nil.
    it 'is an empty list when the keys arrive without their sessions' do
      expect(described_class.call(visible_scope: TimeSession.all, sessions: [],
                                  page_keys: [[project.id, nil, nil, Date.new(2026, 8, 1)]])).to eq([])
    end
  end

  describe 'the month header' do
    # Mutation: format the label with anything but the shared :month_year, or
    # build it with strftime, and the German page starts saying "March".
    it 'names the month in the language of the page, both of them' do
      book(60, on: Time.utc(2026, 3, 15, 10, 0))

      expect(build.first[:label]).to eq('März 2026')
      I18n.with_locale(:en) { expect(build.first[:label]).to eq('March 2026') }
    end
  end

  describe 'an empty page' do
    it 'is an empty list and asks the database nothing' do
      statements = capture_sql do
        expect(described_class.call(visible_scope: TimeSession.all, sessions: [], page_keys: [])).to eq([])
      end

      expect(statements).to be_empty
    end
  end
end
