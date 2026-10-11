# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SmartFolders::Filters::AssociationFilter, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user_a) { create(:user) }
  let(:user_b) { create(:user) }

  # updater_id is nullable on Ticket, perfect for testing NULL handling
  let(:rule) do
    build_stubbed(:smart_folder_rule, field: 'updater_id', operator: operator, value: value)
  end

  subject(:filter) { described_class.new(rule) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:project) { create(:project, organisation: organisation) }

  let!(:ticket_updated_by_a) do
    create(:ticket, project: project, updater_id: user_a.id)
  end

  let!(:ticket_updated_by_b) do
    create(:ticket, project: project, updater_id: user_b.id)
  end

  let!(:ticket_no_updater) do
    create(:ticket, project: project, updater_id: nil)
  end

  def apply_filter
    filter.apply(Ticket.where(project: project), 'Ticket')
  end

  def result_ids
    apply_filter.pluck(:id)
  end

  describe 'operator: equals' do
    let(:operator) { 'equals' }
    let(:value) { user_a.id }

    it 'returns tickets matching the FK value' do
      expect(result_ids).to contain_exactly(ticket_updated_by_a.id)
    end

    it 'excludes tickets with different FK value' do
      expect(result_ids).not_to include(ticket_updated_by_b.id)
    end

    it 'excludes tickets with NULL FK value' do
      expect(result_ids).not_to include(ticket_no_updater.id)
    end

    context 'with non-existent UUID' do
      let(:value) { SecureRandom.uuid }

      it 'returns no results' do
        expect(result_ids).to be_empty
      end
    end

    context 'with blank value' do
      let(:value) { nil }

      it 'returns no results' do
        expect(result_ids).to be_empty
      end
    end

    context 'with empty string value' do
      let(:value) { '' }

      it 'returns no results' do
        expect(result_ids).to be_empty
      end
    end

    context 'with multiple matching tickets' do
      let!(:another_ticket_by_a) do
        create(:ticket, project: project, updater_id: user_a.id)
      end

      it 'returns all matching tickets' do
        expect(result_ids).to contain_exactly(ticket_updated_by_a.id, another_ticket_by_a.id)
      end
    end
  end

  describe 'operator: not_equals' do
    let(:operator) { 'not_equals' }
    let(:value) { user_a.id }

    it 'excludes tickets matching the FK value' do
      expect(result_ids).not_to include(ticket_updated_by_a.id)
    end

    it 'includes tickets with different FK value' do
      expect(result_ids).to include(ticket_updated_by_b.id)
    end

    it 'includes tickets with NULL FK value (OR NULL semantics)' do
      expect(result_ids).to include(ticket_no_updater.id)
    end

    it 'returns all non-matching tickets' do
      expect(result_ids).to contain_exactly(ticket_updated_by_b.id, ticket_no_updater.id)
    end

    context 'with non-existent UUID' do
      let(:value) { SecureRandom.uuid }

      it 'returns all tickets (nothing matches the UUID to exclude)' do
        expect(result_ids).to contain_exactly(
          ticket_updated_by_a.id, ticket_updated_by_b.id, ticket_no_updater.id
        )
      end
    end

    context 'with blank value' do
      let(:value) { nil }

      it 'returns only tickets where column is NOT NULL' do
        expect(result_ids).to contain_exactly(ticket_updated_by_a.id, ticket_updated_by_b.id)
      end

      it 'excludes tickets with NULL FK value' do
        expect(result_ids).not_to include(ticket_no_updater.id)
      end
    end

    context 'with empty string value' do
      let(:value) { '' }

      it 'returns only tickets where column is NOT NULL' do
        expect(result_ids).to contain_exactly(ticket_updated_by_a.id, ticket_updated_by_b.id)
      end
    end
  end

  describe 'unsupported operator' do
    let(:operator) { 'contains' }
    let(:value) { user_a.id }

    it 'returns the query unchanged' do
      expect(result_ids).to contain_exactly(
        ticket_updated_by_a.id, ticket_updated_by_b.id, ticket_no_updater.id
      )
    end

    it 'logs a warning' do
      allow(Rails.logger).to receive(:warn)
      apply_filter
      expect(Rails.logger).to have_received(:warn).with(/Unsupported association operator 'contains'/)
    end
  end

  describe 'unsupported operator with blank value' do
    let(:operator) { 'greater_than' }
    let(:value) { nil }

    it 'returns the query unchanged' do
      expect(result_ids).to contain_exactly(
        ticket_updated_by_a.id, ticket_updated_by_b.id, ticket_no_updater.id
      )
    end
  end

  describe 'non-existent column' do
    let(:operator) { 'equals' }
    let(:value) { user_a.id }
    let(:rule) do
      build_stubbed(:smart_folder_rule, field: 'nonexistent_column_id', operator: operator, value: value)
    end

    it 'returns the query unchanged' do
      expect(result_ids).to contain_exactly(
        ticket_updated_by_a.id, ticket_updated_by_b.id, ticket_no_updater.id
      )
    end

    it 'logs a warning' do
      allow(Rails.logger).to receive(:warn)
      apply_filter
      expect(Rails.logger).to have_received(:warn).with(/Column.*nonexistent_column_id.*not found/)
    end
  end

  describe 'empty scope' do
    let(:operator) { 'equals' }
    let(:value) { user_a.id }

    it 'returns empty result for an empty scope' do
      other_project = create(:project, organisation: organisation)
      result = filter.apply(Ticket.where(project: other_project), 'Ticket')
      expect(result.pluck(:id)).to be_empty
    end
  end

  describe 'chaining with other scopes' do
    let(:operator) { 'equals' }
    let(:value) { user_a.id }

    it 'composes correctly with prior where clauses' do
      scoped_query = Ticket.where(project: project).where.not(id: ticket_updated_by_a.id)
      result = filter.apply(scoped_query, 'Ticket')
      expect(result.pluck(:id)).to be_empty
    end
  end
end
