# frozen_string_literal: true

require 'rails_helper'

# Notification#this_week had no spec at all, which is how it carried the same
# date-range defect as Activity and UserActivity unnoticed: the range was bound with
# Date#end_of_week, a DATE, and Rails binds that as midnight, so the whole last day of
# the week fell outside.
#
#   ... Sun 23:59:59.999999 | Mon 00:00:00 ...
#        ^ last moment in     ^ first moment out
#
# Time is frozen on a Sunday, because a scope that is only wrong on the last day of the
# period is green on six days out of seven - which is exactly why the sibling spec in
# activity_spec.rb went red for the first time on 2026-09-06 at 00:11 UTC and not before.
RSpec.describe Notification, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:recipient) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }

  def notification_at(moment)
    create(:notification, recipient: recipient, organisation: organisation, created_at: moment)
  end

  # The moment a row's latest event reached it (last_event_at) moves when an event
  # folds into it (Notifications::GroupKeyBuilder); its created_at never does. The
  # factory lets both follow created_at, so every proving row here sets them far apart.
  def row(created_at:, last_event_at: created_at, **attributes)
    create(:notification, recipient: recipient, organisation: organisation,
                          created_at: created_at, first_event_at: created_at, last_event_at: last_event_at, **attributes)
  end

  describe '.recent' do
    it 'orders by the latest event, newest first, not by creation' do
      old_but_active = row(created_at: 3.days.ago, last_event_at: 5.minutes.ago)
      new_but_quiet = row(created_at: 1.hour.ago)

      expect(described_class.recent.to_a).to eq([old_but_active, new_but_quiet])
    end

    it 'breaks a tie of the latest event by descending id' do
      # Written in ascending id order, so that a missing tie-break most likely hands
      # them back in the order they were written. The id is random: it only makes the
      # order stable, it says nothing about which row is newer.
      moment = 10.minutes.ago
      ids = Array.new(4) { SecureRandom.uuid }.sort
      # The factory looks the organisation up once per row: setup, not the code under test.
      Prosopite.pause do
        ids.each_with_index { |id, index| row(id: id, created_at: (index + 1).days.ago, last_event_at: moment) }
      end

      expect(described_class.recent.map(&:id)).to eq(ids.reverse)
    end
  end

  describe '.active_in_period' do
    # Monday 2026-11-09, 00:30 in Berlin = Sunday 23:30 UTC.
    around { |example| travel_to(Time.utc(2026, 11, 8, 23, 30)) { example.run } }

    let(:berlin) { ActiveSupport::TimeZone['Berlin'] }

    def in_period(key, time_zone: berlin)
      described_class.active_in_period(key, time_zone: time_zone).to_a
    end

    it "counts a row by the day of its latest event in the reader's zone" do
      # Both created weeks ago. 23:10 UTC on Sunday is 00:10 on Monday in Berlin (this
      # week there), 22:50 UTC is 23:50 on Sunday in Berlin (last week there). In UTC
      # both are Sunday, this week.
      monday_in_berlin = row(created_at: Time.utc(2026, 10, 1, 12), last_event_at: Time.utc(2026, 11, 8, 23, 10))
      sunday_in_berlin = row(created_at: Time.utc(2026, 10, 1, 12), last_event_at: Time.utc(2026, 11, 8, 22, 50))

      expect(in_period('this_week')).to eq([monday_in_berlin])
      expect(in_period('this_week', time_zone: ActiveSupport::TimeZone['UTC']))
        .to contain_exactly(monday_in_berlin, sunday_in_berlin)
    end

    it 'keeps a row created 100 days ago with an event today inside the last 90 days, and leaves out a row whose latest event is 100 days old' do
      revived = row(created_at: 100.days.ago, last_event_at: 5.minutes.ago)
      row(created_at: 100.days.ago, last_event_at: 100.days.ago)

      expect(in_period('90_days')).to eq([revived])
    end

    it 'reads "all" and an unknown key as no window' do
      ancient = row(created_at: Time.utc(2024, 3, 1, 12))

      expect(in_period('all')).to eq([ancient])
      expect(in_period('gestern')).to eq([ancient])
    end
  end

  describe '.this_week' do
    context 'on the last day of the week' do
      around { |example| travel_to(Time.zone.parse('2026-09-06 22:30:00')) { example.run } }

      it 'contains a notification created that very day' do
        expect(described_class.this_week).to include(notification_at(Time.current))
      end

      it 'contains the last moment of the week and excludes the first of the next' do
        last_moment = notification_at(Time.current.end_of_week)
        next_week = notification_at(Time.current.end_of_week + 1.second)

        expect(described_class.this_week).to include(last_moment)
        expect(described_class.this_week).not_to include(next_week)
      end

      it 'contains the first moment of the week and excludes the last of the previous' do
        first_moment = notification_at(Time.current.beginning_of_week)
        previous_week = notification_at(Time.current.beginning_of_week - 1.second)

        expect(described_class.this_week).to include(first_moment)
        expect(described_class.this_week).not_to include(previous_week)
      end
    end
  end
end
