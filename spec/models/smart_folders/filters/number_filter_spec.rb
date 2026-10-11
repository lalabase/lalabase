# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SmartFolders::Filters::NumberFilter, type: :model do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  let(:rule) do
    build_stubbed(:smart_folder_rule, field: 'number', operator: operator, value: value)
  end

  subject(:filter) { described_class.new(rule) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # Test data: tickets with different numbers
  # Ticket.number is assigned automatically via before_create,
  # so use update_column for the NULL case.
  let!(:ticket_10) { create(:ticket, project: project, number: 10) }
  let!(:ticket_20) { create(:ticket, project: project, number: 20) }
  let!(:ticket_30) { create(:ticket, project: project, number: 30) }
  let!(:ticket_nil) do
    t = create(:ticket, project: project)
    t.update_column(:number, nil)
    t
  end

  let(:base_query) { Ticket.where(project: project) }

  def result_ids
    filter.apply(base_query, 'Ticket').pluck(:id)
  end

  def all_ticket_ids
    [ticket_10, ticket_20, ticket_30, ticket_nil].map(&:id)
  end

  # ── Operator: equals ──────────────────────────────────────────────

  describe 'operator: equals' do
    let(:operator) { 'equals' }
    let(:value) { '20' }

    it 'returns tickets with the exact number' do
      expect(result_ids).to contain_exactly(ticket_20.id)
    end

    it 'excludes tickets with different numbers' do
      expect(result_ids).not_to include(ticket_10.id, ticket_30.id)
    end

    it 'excludes tickets with NULL number' do
      expect(result_ids).not_to include(ticket_nil.id)
    end

    context 'with float-compatible string' do
      let(:value) { '20.0' }

      it 'matches integer value via float comparison' do
        expect(result_ids).to contain_exactly(ticket_20.id)
      end
    end

    context 'with no matching value' do
      let(:value) { '999' }

      it 'returns empty result' do
        expect(result_ids).to be_empty
      end
    end
  end

  # ── Operator: not_equals ──────────────────────────────────────────

  describe 'operator: not_equals' do
    let(:operator) { 'not_equals' }
    let(:value) { '20' }

    it 'returns tickets with different numbers' do
      expect(result_ids).to include(ticket_10.id, ticket_30.id)
    end

    it 'excludes the matching ticket' do
      expect(result_ids).not_to include(ticket_20.id)
    end

    it 'includes tickets with NULL number (NULL != 20)' do
      expect(result_ids).to include(ticket_nil.id)
    end
  end

  # ── Operator: greater_than ────────────────────────────────────────

  describe 'operator: greater_than' do
    let(:operator) { 'greater_than' }
    let(:value) { '15' }

    it 'returns tickets with number > value' do
      expect(result_ids).to contain_exactly(ticket_20.id, ticket_30.id)
    end

    it 'excludes tickets with number <= value' do
      expect(result_ids).not_to include(ticket_10.id)
    end

    it 'excludes tickets with NULL number' do
      expect(result_ids).not_to include(ticket_nil.id)
    end

    context 'with exact boundary value' do
      let(:value) { '20' }

      it 'excludes tickets with number equal to value (strictly greater)' do
        expect(result_ids).to contain_exactly(ticket_30.id)
      end
    end
  end

  # ── Operator: less_than ───────────────────────────────────────────

  describe 'operator: less_than' do
    let(:operator) { 'less_than' }
    let(:value) { '25' }

    it 'returns tickets with number < value' do
      expect(result_ids).to contain_exactly(ticket_10.id, ticket_20.id)
    end

    it 'excludes tickets with number >= value' do
      expect(result_ids).not_to include(ticket_30.id)
    end

    it 'excludes tickets with NULL number' do
      expect(result_ids).not_to include(ticket_nil.id)
    end

    context 'with exact boundary value' do
      let(:value) { '20' }

      it 'excludes tickets with number equal to value (strictly less)' do
        expect(result_ids).to contain_exactly(ticket_10.id)
      end
    end
  end

  # ── Operator: between ────────────────────────────────────────────

  describe 'operator: between' do
    let(:operator) { 'between' }
    let(:value) { '15,25' }

    it 'returns tickets within the inclusive range' do
      expect(result_ids).to contain_exactly(ticket_20.id)
    end

    it 'excludes tickets outside the range' do
      expect(result_ids).not_to include(ticket_10.id, ticket_30.id)
    end

    it 'excludes tickets with NULL number' do
      expect(result_ids).not_to include(ticket_nil.id)
    end

    context 'with inclusive boundary values' do
      let(:value) { '10,30' }

      it 'includes tickets at both boundaries' do
        expect(result_ids).to contain_exactly(ticket_10.id, ticket_20.id, ticket_30.id)
      end
    end

    context 'with reversed order (max,min)' do
      let(:value) { '25,15' }

      it 'auto-sorts and returns correct results' do
        expect(result_ids).to contain_exactly(ticket_20.id)
      end
    end

    context 'with equal min and max' do
      let(:value) { '20,20' }

      it 'returns tickets matching the exact value' do
        expect(result_ids).to contain_exactly(ticket_20.id)
      end
    end
  end

  # ── Unsupported Operator ──────────────────────────────────────────

  describe 'unsupported operator' do
    let(:operator) { 'contains' }
    let(:value) { '10' }

    before { allow(rule).to receive(:id).and_return('test-rule-id') }

    it 'returns the query unchanged' do
      expect(result_ids).to contain_exactly(*all_ticket_ids)
    end

    it 'logs a warning' do
      allow(Rails.logger).to receive(:warn)
      filter.apply(base_query, 'Ticket')
      expect(Rails.logger).to have_received(:warn).with(/Unsupported number operator 'contains'/)
    end
  end

  # ── Invalid Input / Parse Errors ──────────────────────────────────

  describe 'invalid number values' do
    let(:operator) { 'equals' }

    before { allow(rule).to receive(:id).and_return('test-rule-id') }

    context 'with non-numeric string' do
      let(:value) { 'abc' }

      it 'returns empty relation' do
        expect(result_ids).to be_empty
      end

      it 'logs an error' do
        allow(Rails.logger).to receive(:error)
        filter.apply(base_query, 'Ticket')
        expect(Rails.logger).to have_received(:error).with(/Invalid number format/)
      end
    end

    context 'with empty string' do
      let(:value) { '' }

      it 'returns empty relation' do
        expect(result_ids).to be_empty
      end
    end

    context 'with nil value' do
      let(:value) { nil }

      it 'returns empty relation' do
        expect(result_ids).to be_empty
      end
    end

    context 'with whitespace-only string' do
      let(:value) { '   ' }

      it 'returns empty relation' do
        expect(result_ids).to be_empty
      end
    end

    context 'with mixed alphanumeric' do
      let(:value) { '12abc' }

      it 'returns empty relation' do
        expect(result_ids).to be_empty
      end
    end
  end

  describe 'invalid range values' do
    let(:operator) { 'between' }

    before { allow(rule).to receive(:id).and_return('test-rule-id') }

    context 'with single value instead of range' do
      let(:value) { '10' }

      it 'returns empty relation' do
        expect(result_ids).to be_empty
      end
    end

    context 'with three values' do
      let(:value) { '10,20,30' }

      it 'returns empty relation' do
        expect(result_ids).to be_empty
      end
    end

    context 'with non-numeric range values' do
      let(:value) { 'abc,xyz' }

      it 'returns empty relation' do
        expect(result_ids).to be_empty
      end
    end

    context 'with nil value' do
      let(:value) { nil }

      it 'returns empty relation' do
        expect(result_ids).to be_empty
      end
    end
  end

  # ── European Decimal Separator ────────────────────────────────────

  describe 'european decimal comma in single-value operators' do
    let(:operator) { 'equals' }
    let(:value) { '20,0' }

    it 'treats comma as decimal separator and matches' do
      expect(result_ids).to contain_exactly(ticket_20.id)
    end
  end

  # ── Non-existent Column ──────────────────────────────────────────

  describe 'non-existent column' do
    let(:operator) { 'equals' }
    let(:value) { '10' }

    before do
      allow(rule).to receive(:get_field_name).with('Ticket').and_return(:nonexistent_column)
    end

    it 'returns the query unchanged' do
      expect(result_ids).to contain_exactly(*all_ticket_ids)
    end

    it 'logs a warning' do
      allow(Rails.logger).to receive(:warn)
      filter.apply(base_query, 'Ticket')
      expect(Rails.logger).to have_received(:warn).with(/nonexistent_column.*not found/)
    end
  end

  # ── Empty Base Query ──────────────────────────────────────────────

  describe 'empty base query' do
    let(:operator) { 'equals' }
    let(:value) { '10' }

    it 'returns empty result when query has no matching records' do
      other_project = create(:project, organisation: organisation)
      ids = filter.apply(Ticket.where(project: other_project), 'Ticket').pluck(:id)
      expect(ids).to be_empty
    end
  end

  # ── Negative Numbers ──────────────────────────────────────────────

  describe 'negative numbers' do
    let(:operator) { 'greater_than' }
    let(:value) { '-5' }

    it 'handles negative values correctly' do
      expect(result_ids).to contain_exactly(ticket_10.id, ticket_20.id, ticket_30.id)
    end
  end

  describe 'negative number in between range' do
    let(:operator) { 'between' }
    let(:value) { '-5,15' }

    it 'handles range with negative lower bound' do
      expect(result_ids).to contain_exactly(ticket_10.id)
    end
  end

  # ── Large Numbers ─────────────────────────────────────────────────

  describe 'large numbers' do
    let(:operator) { 'less_than' }
    let(:value) { '999999999' }

    it 'handles large values correctly' do
      expect(result_ids).to contain_exactly(ticket_10.id, ticket_20.id, ticket_30.id)
    end
  end

  # ── parse_number (unit) ───────────────────────────────────────────

  describe '#parse_number (private)' do
    let(:operator) { 'equals' }
    let(:value) { '1' }

    it 'parses integer strings' do
      expect(filter.send(:parse_number, '42')).to eq(42.0)
    end

    it 'parses float strings' do
      expect(filter.send(:parse_number, '3.14')).to eq(3.14)
    end

    it 'converts european comma to dot' do
      expect(filter.send(:parse_number, '3,14')).to eq(3.14)
    end

    it 'parses negative numbers' do
      expect(filter.send(:parse_number, '-7')).to eq(-7.0)
    end

    it 'raises ArgumentError for non-numeric strings' do
      expect { filter.send(:parse_number, 'abc') }.to raise_error(ArgumentError)
    end

    it 'raises ArgumentError for empty string' do
      expect { filter.send(:parse_number, '') }.to raise_error(ArgumentError)
    end

    it 'handles nil by converting to string first' do
      expect { filter.send(:parse_number, nil) }.to raise_error(ArgumentError)
    end
  end

  # ── parse_number_range (unit) ─────────────────────────────────────

  describe '#parse_number_range (private)' do
    let(:operator) { 'between' }
    let(:value) { '1' }

    it 'parses two comma-separated integers' do
      expect(filter.send(:parse_number_range, '10,20')).to eq([10.0, 20.0])
    end

    it 'auto-sorts reversed range' do
      expect(filter.send(:parse_number_range, '50,10')).to eq([10.0, 50.0])
    end

    it 'handles whitespace around numbers' do
      expect(filter.send(:parse_number_range, ' 10 , 20 ')).to eq([10.0, 20.0])
    end

    it 'raises ArgumentError for single value' do
      expect { filter.send(:parse_number_range, '10') }.to raise_error(ArgumentError)
    end

    it 'raises ArgumentError for three values' do
      expect { filter.send(:parse_number_range, '10,20,30') }.to raise_error(ArgumentError)
    end

    it 'raises ArgumentError for empty string' do
      expect { filter.send(:parse_number_range, '') }.to raise_error(ArgumentError)
    end
  end
end
