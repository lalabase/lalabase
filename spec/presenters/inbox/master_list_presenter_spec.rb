# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Inbox::MasterListPresenter do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket_a) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) } }
  let(:ticket_b) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) } }

  let(:scope) { Notification.where(recipient: user, channel: 'in_app') }

  # last_event_at: when the row's latest event reached it. It moves when an event
  # folds into the row (Notifications::GroupKeyBuilder), created_at does not; the
  # factory lets both follow created_at. happened_at (when that event happened)
  # stays empty unless given, as on a row written before the column: then the row
  # answers last_event_at.
  def notif(ticket, created_at:, last_event_at: created_at, first_event_at: created_at, state: 'queued', **attributes)
    ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: user, organisation: organisation, project: project,
             notifiable: ticket, channel: 'in_app', state: state,
             created_at: created_at, first_event_at: first_event_at, last_event_at: last_event_at,
             read_at: state == 'read' ? created_at : nil, **attributes)
    end
  end

  before { ActsAsTenant.current_tenant = organisation }

  def build(params = {}, options = {})
    described_class.new(
      page: nil,
      scope: scope,
      params: { view_mode: 'grouped' }.merge(params),
      **options
    )
  end

  describe 'Bündelung im grouped-View' do
    it 'fasst mehrere Notifications eines Tickets zu EINER Zeile zusammen' do
      notif(ticket_a, created_at: 3.hours.ago)
      notif(ticket_a, created_at: 2.hours.ago)
      newest_a = notif(ticket_a, created_at: 1.hour.ago)
      notif(ticket_b, created_at: 90.minutes.ago)

      presenter = build

      # 2 tickets → 2 rows (not 4 notifications)
      expect(presenter.notifications.size).to eq(2)
      # The representative of ticket A is the NEWEST notification
      rep_a = presenter.notifications.find { |n| n.notifiable_id == ticket_a.id }
      expect(rep_a.id).to eq(newest_a.id)
    end

    # The page takes the number of bundles from the counts per bundle; until
    # 19.11.2026 every render ran one more COUNT over the DISTINCT ON subquery.
    it 'counts its bundles without a second COUNT over the representatives' do
      notif(ticket_a, created_at: 2.hours.ago)
      notif(ticket_a, created_at: 90.minutes.ago)
      notif(ticket_b, created_at: 1.hour.ago)

      counts = []
      callback = lambda do |*, payload|
        counts << payload[:sql] if payload[:sql].match?(/\ASELECT COUNT\(.*FROM "notifications"/im)
      end
      presenter = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { build }

      expect(presenter.pagy).to have_attributes(count: 2, pages: 1)
      expect(counts.grep(/DISTINCT ON/i)).to be_empty
    end

    # The DISTINCT ON and its window sort every row of the filtered inbox, read
    # ones included, and LIMIT cannot reach into that sort. So it carries the id
    # and the window alone, and the page joins the whole rows of its bundles
    # back. Until 2026-11-27 it sorted notifications.*, the payload with it.
    it 'sorts the representatives over their ids, not over whole rows' do
      notif(ticket_a, created_at: 2.hours.ago)
      newest_a = notif(ticket_a, created_at: 90.minutes.ago)
      newest_b = notif(ticket_b, created_at: 1.hour.ago)

      statements = []
      callback = ->(*, payload) { statements << payload[:sql] if payload[:sql].include?('DISTINCT ON') }
      rows = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { build.notifications.to_a }

      expect(rows.map(&:id)).to eq([newest_b.id, newest_a.id])
      expect(rows.first.payload).to be_a(Hash)
      expect(statements.size).to eq(1)
      expect(statements.first).to match(/DISTINCT ON \([^)]+\) notifications\.id,/)
      expect(statements.first).not_to match(/DISTINCT ON \([^)]+\) notifications\.\*/)
    end

    # The inbox appends pages (endless scroll). A page behind the end is EMPTY:
    # the last page again would hang the same rows under the list a second time.
    it 'answers a page behind the end with no rows, not with the last page again' do
      notif(ticket_a, created_at: 2.hours.ago)
      notif(ticket_b, created_at: 1.hour.ago)

      presenter = build({}, page: '2')

      expect(presenter.pagy).to have_attributes(count: 2, pages: 1, page: 2)
      expect(presenter.notifications).to be_empty
    end

    it 'liefert group_total = Gesamtzahl der Notifications des Tickets' do
      notif(ticket_a, created_at: 3.hours.ago)
      notif(ticket_a, created_at: 2.hours.ago)
      notif(ticket_a, created_at: 1.hour.ago)

      presenter = build
      rep_a = presenter.notifications.first
      expect(presenter.group_total(rep_a)).to eq(3)
    end

    it 'liefert group_unread = Anzahl ungelesener des Tickets' do
      notif(ticket_a, created_at: 3.hours.ago, state: 'read')
      notif(ticket_a, created_at: 2.hours.ago)
      notif(ticket_a, created_at: 1.hour.ago)

      presenter = build
      rep_a = presenter.notifications.first
      expect(presenter.group_unread(rep_a)).to eq(2)
    end

    it 'zeigt ein tagesübergreifend aktives Ticket nur EINMAL, unter dem neuesten Zeitraum' do
      travel_to Time.zone.local(2026, 11, 11, 12) do # a Wednesday
        notif(ticket_a, created_at: 2.days.ago)
        notif(ticket_a, created_at: 1.hour.ago)

        presenter = build

        expect(presenter.notifications.size).to eq(1)
        expect(presenter.grouped_notifications.keys).to eq([:today])
      end
    end

    it 'ordnet die Zeilen den Zeiträumen Heute, Gestern, Diese Woche und Älter zu, in dieser Reihenfolge' do
      travel_to Time.zone.local(2026, 11, 11, 12) do # Wednesday; the week began on Monday the 9th
        ticket_c = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) }
        ticket_d = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) }
        notif(ticket_d, created_at: Time.zone.local(2026, 11, 8, 23)) # Sunday: last week
        notif(ticket_c, created_at: Time.zone.local(2026, 11, 9, 0, 30)) # Monday
        notif(ticket_b, created_at: Time.zone.local(2026, 11, 10, 9)) # yesterday
        notif(ticket_a, created_at: Time.zone.local(2026, 11, 11, 0, 5)) # today

        grouped = build.grouped_notifications

        expect(grouped.keys).to eq(%i[today yesterday this_week older])
        expect(grouped.transform_values { |reps| reps.map(&:notifiable_id) })
          .to eq(today: [ticket_a.id], yesterday: [ticket_b.id], this_week: [ticket_c.id], older: [ticket_d.id])
      end
    end

    it 'zählt gestern als gestern, auch wenn gestern in der Vorwoche lag' do
      travel_to Time.zone.local(2026, 11, 9, 12) do # Monday
        notif(ticket_a, created_at: Time.zone.local(2026, 11, 8, 12)) # Sunday

        expect(build.grouped_notifications.keys).to eq([:yesterday])
      end
    end

    # The day is the reader's (User#time_zone), not the server's: at 00:30 in
    # Berlin the UTC day is still the one before, and everything of the Berlin
    # day before would read "Heute".
    it 'zählt die Tage in der Zeitzone des Lesers, nicht in UTC' do
      berlin = ActiveSupport::TimeZone['Europe/Berlin']
      travel_to berlin.local(2026, 11, 11, 0, 30) do # 23:30 UTC on the 10th
        notif(ticket_a, created_at: berlin.local(2026, 11, 11, 0, 10)) # today in Berlin
        notif(ticket_b, created_at: berlin.local(2026, 11, 10, 15)) # yesterday in Berlin, the same UTC day

        grouped = build({}, time_zone: berlin).grouped_notifications

        expect(grouped.transform_values { |reps| reps.map(&:notifiable_id) })
          .to eq(today: [ticket_a.id], yesterday: [ticket_b.id])
      end
    end
  end

  # A row's latest event (last_event_at) decides which row stands for a bundle, where
  # the bundle stands in the list and under which heading: a row created days ago
  # that got an event a moment ago is the most recent row, as in the token inbox.
  describe 'the latest event of a row' do
    it 'lets the row with the latest event represent the bundle, also when it was created first' do
      old_but_active = notif(ticket_a, created_at: 3.days.ago, last_event_at: 5.minutes.ago)
      notif(ticket_a, created_at: 1.hour.ago)

      presenter = build

      expect(presenter.notifications.map(&:id)).to eq([old_but_active.id])
      expect(presenter.group_total(old_but_active)).to eq(2)
      expect(presenter.group_unread(old_but_active)).to eq(2)
    end

    it 'picks the representative among rows of the same latest event by descending id' do
      # Written in ascending id order, so that a missing tie-break most likely picks the
      # first row written. The id is random: it only makes the choice stable, it says
      # nothing about which row is newer.
      moment = 10.minutes.ago
      ids = Array.new(4) { SecureRandom.uuid }.sort
      ids.each_with_index { |id, index| notif(ticket_a, id: id, created_at: (index + 1).days.ago, last_event_at: moment) }

      presenter = build

      expect(presenter.notifications.map(&:id)).to eq([ids.last])
      expect(presenter.group_total(presenter.notifications.first)).to eq(4)
    end

    it 'orders the bundles by the latest event of their representative' do
      notif(ticket_a, created_at: 3.days.ago, last_event_at: 5.minutes.ago)
      notif(ticket_b, created_at: 1.hour.ago)

      expect(build.notifications.map(&:notifiable_id)).to eq([ticket_a.id, ticket_b.id])
    end

    it 'orders bundles of the same latest event by descending id, so that pages never share or drop a row' do
      # One row per ticket, written in ascending id order: a missing tie-break most likely
      # hands them back in the order they were written.
      moment = 10.minutes.ago
      ids = Array.new(4) { SecureRandom.uuid }.sort
      Prosopite.pause do # setup: the factory reads the organisation once per row
        ids.each_with_index do |id, index|
          ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) }
          notif(ticket, id: id, created_at: (index + 1).days.ago, last_event_at: moment)
        end
      end

      expect(build.notifications.map(&:id)).to eq(ids.reverse)
    end

    it 'puts a bundle created last week with an event today under today' do
      travel_to Time.zone.local(2026, 11, 11, 12) do # a Wednesday; the week began on Monday the 9th
        notif(ticket_a, created_at: Time.zone.local(2026, 11, 4, 10), last_event_at: Time.zone.local(2026, 11, 11, 9))
        notif(ticket_b, created_at: Time.zone.local(2026, 11, 10, 9)) # yesterday

        grouped = build.grouped_notifications

        expect(grouped.transform_values { |reps| reps.map(&:notifiable_id) })
          .to eq(today: [ticket_a.id], yesterday: [ticket_b.id])
      end
    end

    # The event-time twin of the zone example above: both rows were created weeks ago.
    it "counts the day of the latest event in the reader's zone, not in UTC" do
      berlin = ActiveSupport::TimeZone['Europe/Berlin']
      travel_to berlin.local(2026, 11, 11, 0, 30) do # 23:30 UTC on the 10th
        long_ago = berlin.local(2026, 10, 1, 12)
        notif(ticket_a, created_at: long_ago, last_event_at: berlin.local(2026, 11, 11, 0, 10)) # today in Berlin
        notif(ticket_b, created_at: long_ago, last_event_at: berlin.local(2026, 11, 10, 15)) # yesterday in Berlin

        in_berlin = build({}, time_zone: berlin).grouped_notifications
        in_utc = build({}, time_zone: ActiveSupport::TimeZone['UTC']).grouped_notifications

        expect(in_berlin.transform_values { |reps| reps.map(&:notifiable_id) })
          .to eq(today: [ticket_a.id], yesterday: [ticket_b.id])
        # In UTC both events fall on the 10th, which is today there.
        expect(in_utc.transform_values { |reps| reps.map(&:notifiable_id) })
          .to eq(today: [ticket_a.id, ticket_b.id])
      end
    end

    # A row the fanout wrote late arrived after a row of the same ticket whose event
    # happened later. The line of the bundle says what the ticket's newest event was,
    # so the row with the later happened_at speaks for it; the bundle stands where
    # its newest arrival stands, on top, under today.
    #
    # The clock stands at a midday: the rows lie up to three days back from it,
    # and a run in the first half hour after midnight would put the row written
    # 30 minutes ago under yesterday.
    context 'when a row of the ticket was written late' do
      around do |example|
        travel_to(Time.zone.local(2026, 11, 11, 12)) { example.run } # a Wednesday; the week began on Monday the 9th
      end

      let!(:in_time) { notif(ticket_a, created_at: 2.hours.ago) }
      let!(:late) do
        notif(ticket_a, created_at: 1.minute.ago, first_event_at: 3.days.ago, happened_at: 3.days.ago,
                        last_event_at: 1.minute.ago)
      end
      let!(:between) { notif(ticket_b, created_at: 30.minutes.ago) }

      it 'lets the row whose event happened last speak for the bundle' do
        expect(late.last_event_at).to be > in_time.last_event_at
        expect(late.happened_at).to be < in_time.happened_at

        presenter = build

        expect(presenter.notifications.map(&:id)).to eq([in_time.id, between.id])
        expect(presenter.group_total(in_time)).to eq(2)
      end

      it 'stands the bundle at its newest arrival, above a bundle that arrived in between' do
        expect(in_time.last_event_at).to be < between.last_event_at

        grouped = build.grouped_notifications

        expect(grouped.transform_values { |reps| reps.map(&:id) }).to eq(today: [in_time.id, between.id])
      end

      it 'puts the bundle under the day of its newest arrival, not of its representative' do
        at = ->(day, hour) { Time.zone.local(2026, 11, day, hour) }
        in_time.update_columns(created_at: at[2, 9], first_event_at: at[2, 9], last_event_at: at[2, 9])
        late.update_columns(created_at: at[11, 11], first_event_at: at[1, 9], happened_at: at[1, 9],
                            last_event_at: at[11, 11])
        between.update_columns(created_at: at[10, 9], first_event_at: at[10, 9], last_event_at: at[10, 9])

        grouped = build.grouped_notifications

        expect(grouped.transform_values { |reps| reps.map(&:id) })
          .to eq(today: [in_time.id], yesterday: [between.id])
      end
    end

    it 'orders the chronological list by the latest event' do
      old_but_active = notif(ticket_a, created_at: 3.days.ago, last_event_at: 5.minutes.ago)
      new_but_quiet = notif(ticket_b, created_at: 1.hour.ago)

      expect(build(view_mode: 'chronological').notifications.map(&:id)).to eq([old_but_active.id, new_but_quiet.id])
    end
  end

  describe 'chronologischer View (kein Bündeln)' do
    it 'rendert jede Notification einzeln' do
      notif(ticket_a, created_at: 2.hours.ago)
      notif(ticket_a, created_at: 1.hour.ago)

      presenter = build(view_mode: 'chronological')
      expect(presenter.notifications.size).to eq(2)
    end

    it 'answers a page behind the end with no rows, not with the last page again' do
      notif(ticket_a, created_at: 2.hours.ago)
      notif(ticket_b, created_at: 1.hour.ago)

      presenter = build({ view_mode: 'chronological' }, page: '2')

      expect(presenter.pagy).to have_attributes(count: 2, pages: 1, page: 2)
      expect(presenter.notifications).to be_empty
    end

    # The total of the list is counted once; the page takes it instead of a
    # second COUNT over the same rows.
    it 'counts its rows once' do
      notif(ticket_a, created_at: 2.hours.ago)
      notif(ticket_b, created_at: 1.hour.ago)

      counts = []
      callback = lambda do |*, payload|
        counts << payload[:sql] if payload[:sql].match?(/\ASELECT COUNT\(.*FROM "notifications"/i)
      end
      presenter = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        build(view_mode: 'chronological')
      end

      expect(presenter.pagy).to have_attributes(count: 2)
      expect(counts.size).to eq(1)
    end
  end

  # S4: the lane redraws its open row, and the row decides its title by the size of the bundle
  # the LIST drew it for. One row asks the presenter's own rule.
  describe '.bundle_size' do
    let!(:newest) { notif(ticket_a, created_at: 1.hour.ago) }

    before do
      notif(ticket_a, created_at: 2.hours.ago, state: 'read')
      notif(ticket_a, created_at: 3.hours.ago, state: 'archived')
      notif(ticket_b, created_at: 4.hours.ago)
    end

    def size(params = {})
      ActsAsTenant.with_tenant(organisation) { described_class.bundle_size(newest, scope: scope, params: params) }
    end

    it 'counts the notifications about the same subject the list shows: everything but the archive by default' do
      expect(size).to eq(2)
      expect(build.group_total(newest)).to eq(2)
    end

    it 'follows the state filters of the list' do
      expect(size(state_filters: ['unread'])).to eq(1)
      expect(size(state_filters: %w[read unread archived])).to eq(3)
      expect(size('state' => 'read')).to eq(1)
    end

    it 'is 1 in the chronological list, where every row is one notification' do
      expect(size(view_mode: 'chronological')).to eq(1)
    end

    it 'is never below 1, also for a row the filters leave out' do
      expect(size(state_filters: ['archived'])).to eq(1)
      newest.update_columns(state: 'archived')
      expect(size(state_filters: ['unread'])).to eq(1)
    end
  end
end
