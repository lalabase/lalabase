# frozen_string_literal: true

require 'rails_helper'

# What: The numbers of the status table above the time list -- minutes per
#       project and billing state.
# Why:  Two things every figure has to share with the list a click on it opens
#       (S5 of doc/zeiten_filterzeile_und_stand_plan.md): WHO sees what
#       (TimeSessions::ViewingScope) and WHICH window (the period). Both were
#       missing here: the service counted every session in the organisation and
#       documented "No time filter here".
RSpec.describe TimeSessionStatisticsService do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:admin_role)   { create(:admin_role, organisation: organisation) }
  let(:admin)        { create(:user) }
  let(:project1) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Project A') } }
  let(:project2) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Project B') } }
  let(:group) { ActsAsTenant.with_tenant(organisation) { create(:time_session_group, organisation: organisation) } }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
  end

  after { ActsAsTenant.current_tenant = nil }

  def viewing_scope_for(user)
    TimeSessions::ViewingScope.for_organisation(user: user, organisation: organisation)
  end

  def statistics(user: admin, **options)
    described_class.new(organisation: organisation, viewing_scope: viewing_scope_for(user), **options)
                   .calculate_project_statistics
  end

  describe '#calculate_project_statistics' do
    it 'categorizes time sessions correctly' do
      # Billed
      create(:time_session, project: project1, billed: true, duration: 120, billed_at: 1.day.ago, occurred_on: 1.day.ago)

      # In a group, not billed
      create(:time_session, project: project1, billed: false, time_session_group: group, duration: 60, occurred_on: 1.day.ago)

      # Without a group
      create(:time_session, project: project1, billed: false, time_session_group_id: nil, duration: 30, occurred_on: 1.day.ago)

      project1_stat = statistics.find { |s| s[:project] == project1 }

      expect(project1_stat[:durations]).to eq('without_billing' => 30, 'in_billing' => 60, 'billed' => 120)
      expect(project1_stat[:total_duration]).to eq(210)
    end

    # Whitelist positive-iteration: every bucket of the constant is a key, zero
    # included. The panel above iterates the constant and indexes straight into
    # this hash, so a missing key would be a nil comparison rather than a "0".
    it 'carries every bucket of the constant, zero included' do
      create(:time_session, project: project1, billed: false, time_session_group_id: nil, duration: 30,
                            occurred_on: 1.day.ago)

      stat = statistics.find { |s| s[:project] == project1 }

      expect(stat[:durations].keys).to eq(TimeSession::BILLING_STATUS_FILTERS)
      expect(stat[:durations].values_at('in_billing', 'billed')).to eq([0, 0])
    end

    # A project with nothing booked still gets a row, and its zeros must not be
    # the SAME hash as another project's: the empty default used to be one frozen
    # constant, and a dup that went missing would let one project's minutes land
    # on all of them.
    it 'gives each project its own zero row' do
      project1
      project2
      create(:time_session, project: project1, duration: 45, occurred_on: 1.day.ago)

      stats = statistics

      expect(stats.find { |s| s[:project] == project2 }[:durations].values).to all(eq(0))
      expect(stats.find { |s| s[:project] == project1 }[:total_duration]).to eq(45)
    end

    it 'includes all projects with time sessions regardless of age' do
      # Old sessions
      create(:time_session, project: project1, duration: 100, occurred_on: 60.days.ago)
      create(:time_session, project: project2, duration: 100, occurred_on: 60.days.ago)

      stats = statistics

      # Projects are shown even when the sessions are old
      expect(stats.map { |s| s[:project] }).to include(project1, project2)
      expect(stats.first[:total_duration]).to eq(100)
    end

    it 'runs a constant number of queries regardless of project count' do
      project3 = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Project C') }
      # Pause only the setup (factory creates in the loop) — the service call
      # below stays monitored by Prosopite
      Prosopite.pause
      [project1, project2, project3].each do |project|
        create(:time_session, project: project, billed: true, duration: 10, billed_at: 1.day.ago, occurred_on: 1.day.ago)
        create(:time_session, project: project, billed: false, time_session_group: group, duration: 20, occurred_on: 1.day.ago)
        create(:time_session, project: project, billed: false, time_session_group_id: nil, duration: 30, occurred_on: 1.day.ago)
      end
      Prosopite.resume

      # The scope reads the membership rows once, at construction: that is not
      # part of what this example measures.
      scope = viewing_scope_for(admin)

      queries = []
      counter = lambda do |_name, _start, _finish, _id, payload|
        queries << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name])
      end

      stats = nil
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        stats = described_class.new(organisation: organisation, viewing_scope: scope).calculate_project_statistics
      end

      # 1 query for the projects + 1 grouped SUM query — NOT 3 SUMs per project
      expect(queries.size).to be <= 2
      expect(stats.find { |s| s[:project] == project3 }[:total_duration]).to eq(60)
    end

    it 'filters by project_id when provided' do
      create(:time_session, project: project1, duration: 100, occurred_on: 1.day.ago)
      create(:time_session, project: project2, duration: 100, occurred_on: 1.day.ago)

      expect(statistics(project_id: project1.id).map { |s| s[:project] }).to eq([project1])
    end
  end

  # The period (D3). One window for the whole table: every column is narrowed by
  # it, so a row's total stays the sum of its cells.
  describe 'the period' do
    let(:today) { Date.new(2026, 5, 20) }

    before do
      create(:time_session, project: project1, billed: false, time_session_group_id: nil, duration: 30,
                            occurred_on: Time.zone.local(2026, 5, 15, 9, 0))
      create(:time_session, project: project1, billed: false, time_session_group: group, duration: 60,
                            occurred_on: Time.zone.local(2026, 5, 16, 9, 0))
      create(:time_session, project: project1, billed: true, billed_at: Time.zone.local(2026, 1, 10), duration: 120,
                            occurred_on: Time.zone.local(2026, 1, 9, 9, 0))
    end

    it 'counts everything when no bounds are given (the table default)' do
      stat = statistics.find { |s| s[:project] == project1 }

      expect(stat[:total_duration]).to eq(210)
    end

    # The billed 120 minutes of January drop out and the two May bookings stay,
    # which is what "one window for every column" means. The row invariant
    # itself is NOT asserted here: total_duration IS durations.values.sum one
    # line down in the service, so restating it can never fail. It is pinned
    # where the two are independent, on the rendered table
    # (time_sessions_overview_drilldown_spec.rb).
    it 'narrows every column at once' do
      stat = statistics(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 31))
             .find { |s| s[:project] == project1 }

      expect(stat[:durations]).to eq('without_billing' => 30, 'in_billing' => 60, 'billed' => 0)
    end

    # Boundary n-1 / n / n+1 on the edge of the window: a booking ON the last day
    # counts, one a day later does not. `occurred_on` is a timestamp, so an
    # end bound that forgot end_of_day would drop the whole final day.
    it 'includes a booking on the last day of the window, at any hour' do
      create(:time_session, project: project2, duration: 15, occurred_on: Time.zone.local(2026, 5, 20, 23, 30))
      create(:time_session, project: project2, duration: 25, occurred_on: Time.zone.local(2026, 5, 21, 0, 30))

      stat = statistics(start_date: Date.new(2026, 5, 19), end_date: today).find { |s| s[:project] == project2 }

      expect(stat[:total_duration]).to eq(15)
    end

    it 'includes a booking on the first day of the window, at any hour' do
      create(:time_session, project: project2, duration: 15, occurred_on: Time.zone.local(2026, 5, 19, 0, 5))
      create(:time_session, project: project2, duration: 25, occurred_on: Time.zone.local(2026, 5, 18, 23, 55))

      stat = statistics(start_date: Date.new(2026, 5, 19), end_date: today).find { |s| s[:project] == project2 }

      expect(stat[:total_duration]).to eq(15)
    end

    it 'takes an open end: a start alone counts everything after it' do
      stat = statistics(start_date: Date.new(2026, 5, 1), end_date: nil).find { |s| s[:project] == project1 }

      expect(stat[:total_duration]).to eq(90)
    end

    it 'resolves a period key through the same owner the list reads' do
      travel_to Time.zone.local(2026, 5, 20, 12, 0) do
        start_date, end_date = TimeSessions::ListPeriod.bounds_for('this_month')
        stat = statistics(start_date: start_date, end_date: end_date).find { |s| s[:project] == project1 }

        expect(stat[:total_duration]).to eq(90)
      end
    end
  end

  # WHO sees what. The overview is open to Finance roles, not only to admins, so
  # a reader whose tier is :own really can hold this table open. Before S5 it
  # answered from every session in the organisation while the list beside it
  # answered from the reader's own.
  describe 'the viewing scope' do
    let(:member)     { create(:user) }
    let(:colleague)  { create(:user) }
    let(:member_role) { create(:role, organisation: organisation, title: 'Finance') }

    before do
      create(:membership, user: member, organisation: organisation, role: member_role, active: true)
      create(:membership, user: colleague, organisation: organisation, role: member_role, active: true)
      create(:time_session, project: project1, creator: member, duration: 30, occurred_on: 1.day.ago)
      create(:time_session, project: project1, creator: colleague, duration: 70, occurred_on: 1.day.ago)
    end

    it 'gives a :all reader every booking of the project' do
      create(:time_session_permission, user: member, project: project1, can_view_own: true, can_view_all: true)

      stat = statistics(user: member).find { |s| s[:project] == project1 }

      expect(stat[:total_duration]).to eq(100)
    end

    # Mutation probe: drop the viewing_scope.apply from #scoped_sessions and this
    # example answers 100, the colleague's hours included.
    it 'gives a :own reader only their own bookings' do
      create(:time_session_permission, user: member, project: project1, can_view_own: true, can_view_all: false)

      stat = statistics(user: member).find { |s| s[:project] == project1 }

      expect(stat[:total_duration]).to eq(30)
    end

    it 'shows a :none reader no project rows at all' do
      expect(statistics(user: member)).to be_empty
    end

    it 'lists only the projects the reader sees time in' do
      create(:time_session_permission, user: member, project: project1, can_view_own: true, can_view_all: true)
      project2

      expect(statistics(user: member).map { |s| s[:project] }).to eq([project1])
    end
  end

  # Multi-tenancy (the plan's cross-cutting obligation): another organisation's
  # projects and minutes are not in this table, not even for its own admin.
  describe 'cross-organisation isolation' do
    let(:other_organisation) { create(:organisation) }
    let(:other_admin_role)   { create(:admin_role, organisation: other_organisation) }

    before do
      ActsAsTenant.with_tenant(other_organisation) do
        create(:membership, user: admin, organisation: other_organisation, role: other_admin_role, active: true)
        other_project = create(:project, organisation: other_organisation, name: 'Foreign project')
        create(:time_session, project: other_project, organisation: other_organisation, duration: 999,
                              occurred_on: 1.day.ago)
      end
      create(:time_session, project: project1, duration: 45, occurred_on: 1.day.ago)
    end

    it 'counts neither the foreign project nor its minutes' do
      stats = statistics

      expect(stats.map { |s| s[:project].name }).to eq(['Project A'])
      expect(stats.sum { |s| s[:total_duration] }).to eq(45)
    end
  end
end
