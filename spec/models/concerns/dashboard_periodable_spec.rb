# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DashboardPeriodable do
  let(:instance) { Class.new { include DashboardPeriodable }.new }

  describe 'PERIOD_OPTIONS' do
    it 'has the expected period keys in order' do
      keys = DashboardPeriodable::PERIOD_OPTIONS.map(&:first)
      expect(keys).to eq(%w[all_time today this_week this_month last_30_days this_quarter])
    end

    it 'is frozen' do
      expect(DashboardPeriodable::PERIOD_OPTIONS).to be_frozen
      expect(DashboardPeriodable::PERIOD_OPTIONS.first).to be_frozen
    end

    it 'maps each key to an i18n translation key' do
      DashboardPeriodable::PERIOD_OPTIONS.each do |_key, i18n_key|
        expect(i18n_key).to start_with('dashboard.stat_cards.periods.')
      end
    end
  end

  describe 'VALID_PERIODS' do
    it 'is a frozen Set derived from PERIOD_OPTIONS' do
      expect(DashboardPeriodable::VALID_PERIODS).to be_a(Set)
      expect(DashboardPeriodable::VALID_PERIODS).to be_frozen
      expect(DashboardPeriodable::VALID_PERIODS).to eq(
        DashboardPeriodable::PERIOD_OPTIONS.map(&:first).to_set
      )
    end
  end

  describe '#period_range' do
    context 'with all_time' do
      it 'returns nil explicitly' do
        expect(instance.period_range('all_time')).to be_nil
      end
    end

    context 'with today' do
      it 'starts at beginning of current day' do
        range = instance.period_range('today')
        expect(range.begin).to eq(Date.current.beginning_of_day)
      end

      it 'returns an endless range' do
        range = instance.period_range('today')
        expect(range.end).to be_nil
      end
    end

    context 'with this_week' do
      it 'starts at beginning of current week' do
        range = instance.period_range('this_week')
        expect(range.begin).to eq(Date.current.beginning_of_week)
      end

      it 'returns an endless range' do
        range = instance.period_range('this_week')
        expect(range.end).to be_nil
      end
    end

    context 'with this_month' do
      it 'starts at beginning of current month' do
        range = instance.period_range('this_month')
        expect(range.begin).to eq(Date.current.beginning_of_month)
      end

      it 'returns an endless range' do
        range = instance.period_range('this_month')
        expect(range.end).to be_nil
      end
    end

    context 'with last_30_days' do
      it 'starts approximately 30 days ago' do
        range = instance.period_range('last_30_days')
        expect(range.begin).to be_within(2.seconds).of(30.days.ago)
      end

      it 'returns an endless range' do
        range = instance.period_range('last_30_days')
        expect(range.end).to be_nil
      end
    end

    context 'with this_quarter' do
      it 'starts at beginning of current quarter' do
        range = instance.period_range('this_quarter')
        expect(range.begin).to eq(Date.current.beginning_of_quarter)
      end

      it 'returns an endless range' do
        range = instance.period_range('this_quarter')
        expect(range.end).to be_nil
      end
    end

    context 'with unknown period' do
      it 'returns nil' do
        expect(instance.period_range('unknown')).to be_nil
      end

      it 'logs a warning' do
        expect(Rails.logger).to receive(:warn).with(/Unknown period: "unknown"/)
        instance.period_range('unknown')
      end
    end

    context 'with nil period' do
      it 'returns nil' do
        expect(instance.period_range(nil)).to be_nil
      end

      it 'logs a warning' do
        expect(Rails.logger).to receive(:warn).with(/Unknown period: nil/)
        instance.period_range(nil)
      end
    end

    context 'with empty string period' do
      it 'returns nil' do
        expect(instance.period_range('')).to be_nil
      end

      it 'logs a warning' do
        expect(Rails.logger).to receive(:warn).with(/Unknown period: ""/)
        instance.period_range('')
      end
    end

    context 'consistency with PERIOD_OPTIONS' do
      it 'handles every period defined in PERIOD_OPTIONS without logging a warning' do
        DashboardPeriodable::PERIOD_OPTIONS.each do |key, _|
          expect(Rails.logger).not_to receive(:warn)
          instance.period_range(key)
        end
      end
    end
  end

  describe '#apply_period' do
    include ActiveSupport::Testing::TimeHelpers

    let(:organisation) { create(:organisation) }
    let(:project) { create(:project, organisation: organisation) }

    # These examples place records with relative offsets (1.day.ago) and filter them with
    # calendar periods (this_month). On the FIRST of a month 1.day.ago falls into the
    # previous month, so the "inside the period" expectations flipped red once a month and
    # were green again the next day — the suite failed on 2026-08-01 for exactly this.
    # Pinning now to mid-month gives every offset used here room on both sides.
    around { |example| travel_to(Time.zone.local(2026, 6, 15, 12, 0, 0)) { example.run } }

    before { ActsAsTenant.current_tenant = organisation }
    after { ActsAsTenant.current_tenant = nil }

    context 'with all_time period' do
      it 'returns the unfiltered scope' do
        old_ticket = create(:ticket, project: project, organisation: organisation, created_at: 1.year.ago)
        new_ticket = create(:ticket, project: project, organisation: organisation, created_at: 1.day.ago)

        result = instance.apply_period(project.tickets, 'all_time')
        expect(result.pluck(:id)).to match_array([old_ticket.id, new_ticket.id])
      end
    end

    context 'with unknown period' do
      it 'returns the unfiltered scope (same as all_time)' do
        old_ticket = create(:ticket, project: project, organisation: organisation, created_at: 1.year.ago)
        new_ticket = create(:ticket, project: project, organisation: organisation, created_at: 1.day.ago)

        result = instance.apply_period(project.tickets, 'nonexistent')
        expect(result.pluck(:id)).to match_array([old_ticket.id, new_ticket.id])
      end
    end

    context 'with nil period' do
      it 'returns the unfiltered scope' do
        old_ticket = create(:ticket, project: project, organisation: organisation, created_at: 1.year.ago)

        result = instance.apply_period(project.tickets, nil)
        expect(result).to include(old_ticket)
      end
    end

    context 'filtering by default column (created_at)' do
      it 'includes records within the period' do
        new_ticket = create(:ticket, project: project, organisation: organisation, created_at: 1.day.ago)

        result = instance.apply_period(project.tickets, 'this_month')
        expect(result).to include(new_ticket)
      end

      it 'excludes records outside the period' do
        old_ticket = create(:ticket, project: project, organisation: organisation, created_at: 2.months.ago)

        result = instance.apply_period(project.tickets, 'this_month')
        expect(result).not_to include(old_ticket)
      end
    end

    context 'filtering by custom column (symbol)' do
      it 'filters on the specified column' do
        old_ticket = create(:ticket, project: project, organisation: organisation)
        new_ticket = create(:ticket, project: project, organisation: organisation)
        old_ticket.update_column(:updated_at, 2.months.ago)

        result = instance.apply_period(project.tickets, 'this_month', column: :updated_at)
        expect(result).to include(new_ticket)
        expect(result).not_to include(old_ticket)
      end
    end

    context 'filtering by custom column (string with table prefix)' do
      it 'filters using a fully qualified column name' do
        old_ticket = create(:ticket, project: project, organisation: organisation, created_at: 2.months.ago)
        new_ticket = create(:ticket, project: project, organisation: organisation, created_at: 1.day.ago)

        result = instance.apply_period(project.tickets, 'this_month', column: 'tickets.created_at')
        expect(result).to include(new_ticket)
        expect(result).not_to include(old_ticket)
      end
    end

    context 'boundary: record exactly at period start' do
      it 'includes a record created exactly at the beginning of the period' do
        start_of_month = Date.current.beginning_of_month
        boundary_ticket = create(:ticket, project: project, organisation: organisation, created_at: start_of_month)

        result = instance.apply_period(project.tickets, 'this_month')
        expect(result).to include(boundary_ticket)
      end
    end

    context 'boundary: record just before period start' do
      it 'excludes a record created just before the period' do
        just_before = Date.current.beginning_of_month - 1.second
        excluded_ticket = create(:ticket, project: project, organisation: organisation, created_at: just_before)

        result = instance.apply_period(project.tickets, 'this_month')
        expect(result).not_to include(excluded_ticket)
      end
    end

    context 'with empty scope' do
      it 'returns an empty relation' do
        result = instance.apply_period(project.tickets, 'this_month')
        expect(result).to be_empty
      end
    end

    context 'scope is not mutated' do
      it 'returns a new relation without modifying the original scope' do
        create(:ticket, project: project, organisation: organisation, created_at: 2.months.ago)
        create(:ticket, project: project, organisation: organisation, created_at: 1.day.ago)

        original_scope = project.tickets
        original_count = original_scope.count

        instance.apply_period(original_scope, 'this_month')
        expect(original_scope.count).to eq(original_count)
      end
    end
  end
end
