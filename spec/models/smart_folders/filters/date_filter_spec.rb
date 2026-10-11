# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SmartFolders::Filters::DateFilter, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  let(:smart_folder) do
    create(:smart_folder, organisation: organisation, user: user, project: project,
                          target_object_type: 'Ticket')
  end
  let(:rule_group) { create(:smart_folder_rule_group, smart_folder: smart_folder) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
  end

  after { ActsAsTenant.current_tenant = nil }

  # Creates a rule with a valid value, then overrides it via update_column
  # so that model validations are bypassed (for edge-case tests).
  def build_rule(field:, operator:, value:, bypass_validation: false)
    if bypass_validation
      valid_value = %w[within_days in_the_last_days].include?(operator) ? '7' : '2025-01-01'
      rule = create(:smart_folder_rule,
                    smart_folder_rule_group: rule_group,
                    field: field, operator: operator, value: valid_value)
      rule.update_column(:value, value)
      rule.reload
    else
      create(:smart_folder_rule,
             smart_folder_rule_group: rule_group,
             field: field, operator: operator, value: value)
    end
  end

  def apply_filter(rule, query: Ticket.where(project: project), item_type: 'Ticket')
    described_class.new(rule).apply(query, item_type)
  end

  # -- Test data: tickets with various created_at values --

  let!(:ticket_before) do
    create(:ticket, project: project).tap do |t|
      t.update_column(:created_at, Time.zone.local(2025, 6, 10, 14, 30))
    end
  end

  let!(:ticket_on_day) do
    create(:ticket, project: project).tap do |t|
      t.update_column(:created_at, Time.zone.local(2025, 6, 15, 9, 0))
    end
  end

  let!(:ticket_on_day_late) do
    create(:ticket, project: project).tap do |t|
      t.update_column(:created_at, Time.zone.local(2025, 6, 15, 23, 59, 59))
    end
  end

  let!(:ticket_after) do
    create(:ticket, project: project).tap do |t|
      t.update_column(:created_at, Time.zone.local(2025, 6, 20, 8, 0))
    end
  end

  def result_ids(rule)
    apply_filter(rule).pluck(:id)
  end

  def all_ticket_ids
    [ticket_before, ticket_on_day, ticket_on_day_late, ticket_after].map(&:id)
  end

  # ── Operator: equals ──────────────────────────────────────────

  describe 'operator: equals' do
    it 'returns tickets created on the given date (full day)' do
      rule = build_rule(field: 'created_at', operator: 'equals', value: '2025-06-15')

      ids = result_ids(rule)
      expect(ids).to contain_exactly(ticket_on_day.id, ticket_on_day_late.id)
    end

    it 'excludes tickets from other dates' do
      rule = build_rule(field: 'created_at', operator: 'equals', value: '2025-06-15')

      ids = result_ids(rule)
      expect(ids).not_to include(ticket_before.id, ticket_after.id)
    end

    it 'returns empty when no tickets match the date' do
      rule = build_rule(field: 'created_at', operator: 'equals', value: '2099-01-01')

      expect(result_ids(rule)).to be_empty
    end

    it 'skips rule for invalid date and returns unmodified query' do
      rule = build_rule(field: 'created_at', operator: 'equals', value: 'not-a-date', bypass_validation: true)

      expect(result_ids(rule)).to contain_exactly(*all_ticket_ids)
    end

    it 'skips rule for blank value' do
      rule = build_rule(field: 'created_at', operator: 'equals', value: '', bypass_validation: true)

      expect(result_ids(rule)).to contain_exactly(*all_ticket_ids)
    end
  end

  # ── Operator: not_equals ────────────────────────────────────────

  describe 'operator: not_equals' do
    it 'excludes tickets from the given date' do
      rule = build_rule(field: 'created_at', operator: 'not_equals', value: '2025-06-15')

      ids = result_ids(rule)
      expect(ids).to contain_exactly(ticket_before.id, ticket_after.id)
    end

    it 'does not return tickets on the given date' do
      rule = build_rule(field: 'created_at', operator: 'not_equals', value: '2025-06-15')

      ids = result_ids(rule)
      expect(ids).not_to include(ticket_on_day.id, ticket_on_day_late.id)
    end

    it 'skips rule for invalid date' do
      rule = build_rule(field: 'created_at', operator: 'not_equals', value: 'garbage', bypass_validation: true)

      expect(result_ids(rule)).to contain_exactly(*all_ticket_ids)
    end
  end

  # ── Operator: before ────────────────────────────────────────────

  describe 'operator: before' do
    it 'returns tickets strictly before the given date' do
      rule = build_rule(field: 'created_at', operator: 'before', value: '2025-06-15')

      expect(result_ids(rule)).to contain_exactly(ticket_before.id)
    end

    it 'excludes tickets on the given date (boundary)' do
      rule = build_rule(field: 'created_at', operator: 'before', value: '2025-06-15')

      expect(result_ids(rule)).not_to include(ticket_on_day.id, ticket_on_day_late.id)
    end

    it 'returns empty when all tickets are after the date' do
      rule = build_rule(field: 'created_at', operator: 'before', value: '2020-01-01')

      expect(result_ids(rule)).to be_empty
    end

    it 'skips rule for blank value' do
      rule = build_rule(field: 'created_at', operator: 'before', value: '', bypass_validation: true)

      expect(result_ids(rule)).to contain_exactly(*all_ticket_ids)
    end
  end

  # ── Operator: after ─────────────────────────────────────────────

  describe 'operator: after' do
    it 'returns tickets strictly after the given date' do
      rule = build_rule(field: 'created_at', operator: 'after', value: '2025-06-15')

      expect(result_ids(rule)).to contain_exactly(ticket_after.id)
    end

    it 'excludes tickets on the given date (boundary)' do
      rule = build_rule(field: 'created_at', operator: 'after', value: '2025-06-15')

      expect(result_ids(rule)).not_to include(ticket_on_day.id, ticket_on_day_late.id)
    end

    it 'returns all tickets when date is far in the past' do
      rule = build_rule(field: 'created_at', operator: 'after', value: '2000-01-01')

      expect(result_ids(rule)).to contain_exactly(*all_ticket_ids)
    end

    it 'skips rule for nil value' do
      rule = build_rule(field: 'created_at', operator: 'after', value: nil, bypass_validation: true)

      expect(result_ids(rule)).to contain_exactly(*all_ticket_ids)
    end
  end

  # ── Operator: between ───────────────────────────────────────────

  describe 'operator: between' do
    it 'returns tickets within the inclusive date range' do
      rule = build_rule(field: 'created_at', operator: 'between', value: '2025-06-14,2025-06-16')

      ids = result_ids(rule)
      expect(ids).to contain_exactly(ticket_on_day.id, ticket_on_day_late.id)
    end

    it 'includes tickets on the boundary dates' do
      rule = build_rule(field: 'created_at', operator: 'between', value: '2025-06-10,2025-06-15')

      ids = result_ids(rule)
      expect(ids).to contain_exactly(ticket_before.id, ticket_on_day.id, ticket_on_day_late.id)
    end

    it 'auto-swaps reversed date range' do
      rule = build_rule(field: 'created_at', operator: 'between', value: '2025-06-20,2025-06-10')

      ids = result_ids(rule)
      expect(ids).to contain_exactly(*all_ticket_ids)
    end

    it 'handles single date as start and end' do
      rule = build_rule(field: 'created_at', operator: 'between', value: '2025-06-15')

      ids = result_ids(rule)
      expect(ids).to contain_exactly(ticket_on_day.id, ticket_on_day_late.id)
    end

    it 'defaults to today for blank range' do
      rule = build_rule(field: 'created_at', operator: 'between', value: '', bypass_validation: true)

      expect { result_ids(rule) }.not_to raise_error
    end

    it 'skips rule when all dates in range are unparseable' do
      rule = build_rule(field: 'created_at', operator: 'between', value: 'abc,xyz', bypass_validation: true)

      expect(result_ids(rule)).to contain_exactly(*all_ticket_ids)
    end

    it 'uses valid date when one of two is unparseable' do
      rule = build_rule(field: 'created_at', operator: 'between', value: '2025-06-15,garbage', bypass_validation: true)

      ids = result_ids(rule)
      expect(ids).to contain_exactly(ticket_on_day.id, ticket_on_day_late.id)
    end
  end

  # ── Operator: within_days / in_the_last_days ────────────────────

  describe 'operator: within_days' do
    it 'returns tickets from the last N days' do
      ticket_after.update_column(:created_at, 1.day.ago)

      rule = build_rule(field: 'created_at', operator: 'within_days', value: '3')
      ids = result_ids(rule)

      expect(ids).to include(ticket_after.id)
    end

    it 'excludes tickets older than N days' do
      rule = build_rule(field: 'created_at', operator: 'within_days', value: '1')
      ids = result_ids(rule)

      expect(ids).not_to include(ticket_before.id, ticket_on_day.id)
    end

    it 'defaults to 1 day for zero value and logs warning' do
      rule = build_rule(field: 'created_at', operator: 'within_days', value: '0')

      expect(Rails.logger).to receive(:warn).with(/Invalid days value '0'/)
      result_ids(rule)
    end

    it 'defaults to 1 day for negative value and logs warning' do
      rule = build_rule(field: 'created_at', operator: 'within_days', value: '-5', bypass_validation: true)

      expect(Rails.logger).to receive(:warn).with(/Invalid days value '-5'/)
      result_ids(rule)
    end

    it 'handles non-numeric value (defaults to 0 → 1) and logs warning' do
      rule = build_rule(field: 'created_at', operator: 'within_days', value: 'abc', bypass_validation: true)

      expect(Rails.logger).to receive(:warn).with(/Invalid days value 'abc'/)
      result_ids(rule)
    end
  end

  describe 'operator: in_the_last_days' do
    it 'behaves identically to within_days' do
      ticket_after.update_column(:created_at, 1.day.ago)

      rule = build_rule(field: 'created_at', operator: 'in_the_last_days', value: '3')
      ids = result_ids(rule)

      expect(ids).to include(ticket_after.id)
    end
  end

  # ── Operator: date presets ──────────────────────────────────────

  describe 'operator: date presets (SmartFolders::DatePresets)' do
    # A preset is the operator and carries no value; the range is read from the one
    # table the bar's list reads too, so both lists answer alike at the boundary.
    # Pinned at n-1 / n / n+1 around the boundary with travel_to, not freeze_time.
    let(:wednesday) { Time.zone.local(2026, 9, 9, 12, 0) } # 2026-09-09 is a Wednesday

    def preset_rule(preset)
      build_rule(field: 'created_at', operator: preset, value: nil)
    end

    it 'this_week keeps the ticket from Monday 00:00 and drops the one from Sunday 23:59' do
      travel_to(wednesday) do
        ticket_before.update_column(:created_at, Time.zone.local(2026, 9, 6, 23, 59, 59)) # Sunday, n-1
        ticket_on_day.update_column(:created_at, Time.zone.local(2026, 9, 7, 0, 0))       # Monday, n
        ticket_after.update_column(:created_at, Time.zone.local(2026, 9, 8, 9, 0))        # Tuesday, n+1

        expect(result_ids(preset_rule('this_week'))).to contain_exactly(ticket_on_day.id, ticket_after.id)
      end
    end

    it 'today keeps the whole day and nothing of yesterday' do
      travel_to(wednesday) do
        ticket_before.update_column(:created_at, Time.zone.local(2026, 9, 8, 23, 59, 59))
        ticket_on_day.update_column(:created_at, Time.zone.local(2026, 9, 9, 0, 0))
        ticket_on_day_late.update_column(:created_at, Time.zone.local(2026, 9, 9, 23, 59, 59))

        expect(result_ids(preset_rule('today'))).to contain_exactly(ticket_on_day.id, ticket_on_day_late.id)
      end
    end

    it 'answers exactly like the bar for every preset' do
      # Six rules and six bar queries in one example: Prosopite reads the repetition as N+1.
      Prosopite.pause
      travel_to(wednesday) do
        ticket_before.update_column(:created_at, Time.zone.local(2026, 9, 6, 23, 59, 59))     # Sunday
        ticket_on_day.update_column(:created_at, Time.zone.local(2026, 9, 7, 0, 0))           # Monday
        ticket_on_day_late.update_column(:created_at, Time.zone.local(2026, 9, 8, 23, 59, 59)) # yesterday
        ticket_after.update_column(:created_at, Time.zone.local(2026, 9, 9, 0, 0)) # today

        SmartFolders::DatePresets::KEYS.each do |preset|
          bar = AdHocFilterService.new(project, { 'created_at' => [preset] }).apply(Ticket.where(project: project)).pluck(:id)
          expect(bar).not_to be_empty, "preset #{preset} found nothing in the bar: the oracle is empty"
          expect(result_ids(preset_rule(preset))).to match_array(bar), "preset #{preset}: folder and bar differ"
        end
      end
    ensure
      Prosopite.resume
    end
  end

  # ── Unsupported Operator ────────────────────────────────────────

  describe 'unsupported operator' do
    it 'returns query unchanged and logs warning' do
      rule = build_rule(field: 'created_at', operator: 'equals', value: '2025-06-15')
      rule.update_column(:operator, 'fancy_op')
      rule.reload

      expect(Rails.logger).to receive(:warn).with(/Unsupported date operator 'fancy_op'/)

      expect(result_ids(rule)).to contain_exactly(*all_ticket_ids)
    end
  end

  # ── Non-existent Column ────────────────────────────────────────

  describe 'non-existent column' do
    it 'returns query unchanged and logs warning' do
      rule = build_rule(field: 'created_at', operator: 'equals', value: '2025-06-15')
      allow(rule).to receive(:get_field_name).with('Ticket').and_return(:nonexistent_column)

      expect(Rails.logger).to receive(:warn).with(/nonexistent_column/)

      expect(result_ids(rule)).to contain_exactly(*all_ticket_ids)
    end
  end

  # ── Date Format Parsing ────────────────────────────────────────

  describe 'date format support' do
    context 'with ISO 8601 format (YYYY-MM-DD)' do
      it 'parses correctly' do
        rule = build_rule(field: 'created_at', operator: 'equals', value: '2025-06-15')

        expect(result_ids(rule)).to contain_exactly(ticket_on_day.id, ticket_on_day_late.id)
      end
    end

    context 'with German format (DD.MM.YYYY)' do
      it 'parses correctly' do
        rule = build_rule(field: 'created_at', operator: 'equals', value: '15.06.2025')

        expect(result_ids(rule)).to contain_exactly(ticket_on_day.id, ticket_on_day_late.id)
      end

      it 'handles single-digit day and month' do
        rule = build_rule(field: 'created_at', operator: 'equals', value: '10.6.2025')

        expect(result_ids(rule)).to contain_exactly(ticket_before.id)
      end
    end

    context 'with US format (MM/DD/YYYY)' do
      it 'parses correctly' do
        rule = build_rule(field: 'created_at', operator: 'equals', value: '06/15/2025', bypass_validation: true)

        expect(result_ids(rule)).to contain_exactly(ticket_on_day.id, ticket_on_day_late.id)
      end

      it 'handles single-digit month and day' do
        rule = build_rule(field: 'created_at', operator: 'equals', value: '6/10/2025', bypass_validation: true)

        expect(result_ids(rule)).to contain_exactly(ticket_before.id)
      end
    end
  end

  # ── Empty Dataset ──────────────────────────────────────────────

  describe 'empty dataset' do
    it 'returns empty relation without errors' do
      other_project = create(:project, organisation: organisation)
      rule = build_rule(field: 'created_at', operator: 'equals', value: '2025-06-15')
      result = apply_filter(rule, query: Ticket.where(project: other_project))

      expect(result).to be_empty
      expect(result).to be_a(ActiveRecord::Relation)
    end
  end

  # ── Different Date Fields ──────────────────────────────────────

  describe 'filtering on updated_at' do
    before do
      ticket_on_day.update_column(:updated_at, Time.zone.local(2025, 12, 25, 10, 0))
    end

    it 'filters on the correct column' do
      rule = build_rule(field: 'updated_at', operator: 'equals', value: '2025-12-25')
      ids = result_ids(rule)

      expect(ids).to contain_exactly(ticket_on_day.id)
    end
  end

  # ── Error Resilience ───────────────────────────────────────────

  describe 'error resilience' do
    it 'catches unexpected errors and returns query unchanged' do
      rule = build_rule(field: 'created_at', operator: 'equals', value: '2025-06-15')

      allow_any_instance_of(described_class).to receive(:apply_operator).and_raise(RuntimeError, 'boom')

      expect(Rails.logger).to receive(:error).at_least(:once)

      expect(result_ids(rule)).to contain_exactly(*all_ticket_ids)
    end
  end

  # ── Private Methods (Unit Tests) ───────────────────────────────

  describe '#parse_date (private)' do
    let(:filter) { described_class.new(build_rule(field: 'created_at', operator: 'equals', value: '2025-01-01')) }

    it 'parses ISO format' do
      expect(filter.send(:parse_date, '2025-06-15')).to eq(Date.new(2025, 6, 15))
    end

    it 'parses German format' do
      expect(filter.send(:parse_date, '15.06.2025')).to eq(Date.new(2025, 6, 15))
    end

    it 'parses US format' do
      expect(filter.send(:parse_date, '06/15/2025')).to eq(Date.new(2025, 6, 15))
    end

    it 'returns nil for blank string' do
      expect(filter.send(:parse_date, '')).to be_nil
    end

    it 'returns nil for nil' do
      expect(filter.send(:parse_date, nil)).to be_nil
    end

    it 'returns nil for unparseable string' do
      expect(filter.send(:parse_date, 'not-a-date')).to be_nil
    end

    it 'strips whitespace before parsing' do
      expect(filter.send(:parse_date, '  2025-06-15  ')).to eq(Date.new(2025, 6, 15))
    end

    it 'returns nil for invalid date like Feb 30' do
      expect(filter.send(:parse_date, '2025-02-30')).to be_nil
    end

    it 'returns nil for invalid German date like 32.01.2025' do
      expect(filter.send(:parse_date, '32.01.2025')).to be_nil
    end

    it 'returns nil for invalid US date like 13/32/2025' do
      expect(filter.send(:parse_date, '13/32/2025')).to be_nil
    end

    it 'handles Date.parse fallback for other valid formats' do
      expect(filter.send(:parse_date, 'June 15, 2025')).to eq(Date.new(2025, 6, 15))
    end
  end

  describe '#parse_date_range (private)' do
    let(:filter) { described_class.new(build_rule(field: 'created_at', operator: 'between', value: '2025-01-01,2025-01-31')) }

    it 'parses two comma-separated ISO dates' do
      result = filter.send(:parse_date_range, '2025-01-10,2025-01-20')
      expect(result).to eq([Date.new(2025, 1, 10), Date.new(2025, 1, 20)])
    end

    it 'auto-sorts reversed range' do
      result = filter.send(:parse_date_range, '2025-06-20,2025-06-10')
      expect(result).to eq([Date.new(2025, 6, 10), Date.new(2025, 6, 20)])
    end

    it 'uses same date for start and end with single date' do
      result = filter.send(:parse_date_range, '2025-06-15')
      expect(result).to eq([Date.new(2025, 6, 15), Date.new(2025, 6, 15)])
    end

    it 'returns today for blank string' do
      result = filter.send(:parse_date_range, '')
      expect(result).to eq([Date.current, Date.current])
    end

    it 'returns today for nil' do
      result = filter.send(:parse_date_range, nil)
      expect(result).to eq([Date.current, Date.current])
    end

    it 'raises ArgumentError when no dates can be parsed' do
      expect do
        filter.send(:parse_date_range, 'abc,xyz')
      end.to raise_error(ArgumentError)
    end

    it 'uses only the valid date when one is unparseable' do
      result = filter.send(:parse_date_range, '2025-06-15,garbage')
      expect(result).to eq([Date.new(2025, 6, 15), Date.new(2025, 6, 15)])
    end

    it 'ignores extra dates beyond the first two' do
      result = filter.send(:parse_date_range, '2025-01-01,2025-06-15,2025-12-31')
      expect(result).to eq([Date.new(2025, 1, 1), Date.new(2025, 6, 15)])
    end

    it 'handles mixed date formats in range' do
      result = filter.send(:parse_date_range, '15.06.2025,06/20/2025')
      expect(result).to eq([Date.new(2025, 6, 15), Date.new(2025, 6, 20)])
    end
  end
end
