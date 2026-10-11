# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Dashboard::DailyBriefing do
  let(:organisation) { create(:organisation) }
  let(:user)        { create(:user) }
  let(:other_user)  { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
    admin_role = create(:role, organisation: organisation, title: 'account_admin')
    create(:membership, user: user, organisation: organisation, role: admin_role)
  end
  after { ActsAsTenant.current_tenant = nil }

  describe '#recent_activities_others (Activity-Lane Orthogonalisierung)' do
    let(:project) { create(:project, organisation: organisation) }
    let(:ticket_notified) { create(:ticket, project: project) }
    let(:ticket_ambient)  { create(:ticket, project: project) }

    let(:briefing) { described_class.new(user: user, organisation: organisation) }

    # The "In the background" briefing lane shows only activities for trackables that
    # the user has NO notification about. Otherwise duplicate noise arose
    # between the notifications lane and the activity lane.
    it 'excludes activities for trackables the user has a notification about' do
      create(:activity, trackable: ticket_notified, actor: other_user, action: 'created', organisation: organisation)
      create(:activity, trackable: ticket_ambient,  actor: other_user, action: 'created', organisation: organisation)

      create(:notification, recipient: user, organisation: organisation,
                            notifiable: ticket_notified, channel: 'in_app')

      groups = briefing.recent_activities_others
      trackables = groups.map(&:trackable)

      expect(trackables).to include(ticket_ambient)
      expect(trackables).not_to include(ticket_notified)
    end

    it 'includes all activities when user has no notifications' do
      create(:activity, trackable: ticket_notified, actor: other_user, action: 'created', organisation: organisation)
      create(:activity, trackable: ticket_ambient,  actor: other_user, action: 'created', organisation: organisation)

      groups = briefing.recent_activities_others
      expect(groups.map(&:trackable)).to contain_exactly(ticket_notified, ticket_ambient)
    end

    it 'still excludes activities from the user themselves' do
      create(:activity, trackable: ticket_ambient, actor: user, action: 'created', organisation: organisation)

      expect(briefing.recent_activities_others).to be_empty
    end
  end

  describe '#period_hours' do
    let(:project) { create(:project, organisation: organisation) }
    # Wed of the current week (inside every period we test) at noon, to avoid any
    # day-boundary ambiguity.
    let(:now) { Time.current.beginning_of_week + 2.days + 12.hours }
    let(:briefing) { described_class.new(user: user, organisation: organisation, now: now) }

    def track(minutes:, on:, billed: false, creator: user)
      create(:time_session, project: project, creator: creator, organisation: organisation,
                            occurred_on: on, duration: minutes, billed: billed)
    end

    it 'sums tracked and unbilled hours for the viewer in the period' do
      track(minutes: 120, on: now, billed: false)
      track(minutes: 60,  on: now, billed: true)

      data = briefing.period_hours('this_week')
      expect(data[:tracked]).to eq(3.0)   # 180 min
      expect(data[:unbilled]).to eq(2.0)  # 120 min
      expect(data[:period_key]).to eq('this_week')
    end

    it 'counts only the viewer’s own sessions, not other users’' do
      track(minutes: 120, on: now, creator: user)
      track(minutes: 300, on: now, creator: other_user)

      expect(briefing.period_hours('this_week')[:tracked]).to eq(2.0)
    end

    it 'excludes sessions outside the selected window (this_week vs last week)' do
      track(minutes: 120, on: now)                 # this week
      track(minutes: 300, on: now - 8.days)        # last week

      expect(briefing.period_hours('this_week')[:tracked]).to eq(2.0)
      # The wider month window picks the older session up.
      expect(briefing.period_hours('this_month')[:tracked]).to be >= 2.0
    end

    it 'isolates per organisation' do
      other_org = create(:organisation)
      ActsAsTenant.with_tenant(other_org) do
        other_project = create(:project, organisation: other_org)
        create(:time_session, project: other_project, creator: user, organisation: other_org,
                              occurred_on: now, duration: 999, billed: false)
      end
      track(minutes: 120, on: now)

      expect(briefing.period_hours('this_week')[:tracked]).to eq(2.0)
    end

    it 'returns one bucket per day for daily periods and 3 for the quarter' do
      expect(briefing.period_hours('this_week')[:buckets].size).to eq(7)
      expect(briefing.period_hours('last_10_days')[:buckets].size).to eq(10)
      expect(briefing.period_hours('this_quarter')[:buckets].size).to eq(3)
    end

    it 'puts each session’s hours in the right daily bucket and flags the current one' do
      track(minutes: 60,  on: now.beginning_of_week) # Monday this week -> first bucket
      track(minutes: 120, on: now)                   # today (Wed) -> current bucket

      buckets = briefing.period_hours('this_week')[:buckets] # Mon..Sun

      expect(buckets.first[:hours]).to eq(1.0)                      # Monday
      expect(buckets.count { |b| b[:current] }).to eq(1)
      expect(buckets.find { |b| b[:current] }[:hours]).to eq(2.0)   # today
      expect(buckets.sum { |b| b[:hours] }).to eq(3.0)
    end

    it 'memoises per period key' do
      expect(briefing.period_hours('this_week')).to equal(briefing.period_hours('this_week'))
    end

    # The whole point of the drill-down: clicking the widget must land on a list whose
    # sum equals the figure shown. Both sides go through Overview::TimePeriod, so this
    # locks them together (same window, same creator, end-inclusive, all billing states).
    it 'the widget figure equals the drill-down filter sum for the same period + me' do
      track(minutes: 120, on: now, billed: false)
      track(minutes: 60,  on: now, billed: true)
      track(minutes: 300, on: now - 8.days) # out of week -> excluded both sides
      track(minutes: 999, on: now, creator: other_user) # not me -> excluded both sides

      widget = briefing.period_hours('this_week')
      period = Overview::TimePeriod.range_for('this_week', now: now)
      drill = TimeSessionFilterService.new(
        base_query: TimeSession.where(organisation: organisation),
        creator_id: user.id,
        start_date: period.start_at.to_date.to_s,
        end_date: period.end_at.to_date.to_s,
        status_filters: %w[billed in_billing without_billing]
      ).call

      expect((drill.sum(:duration) / 60.0).round(1)).to eq(widget[:tracked])
      expect(widget[:tracked]).to eq(3.0)
    end
  end
end
