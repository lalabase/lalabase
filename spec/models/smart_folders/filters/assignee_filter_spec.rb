# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SmartFolders::Filters::AssigneeFilter, type: :model do
  let(:organisation) { create(:organisation) }
  let(:assigned_user) { create(:user) }
  let(:other_user) { create(:user) }

  let(:rule) do
    build_stubbed(:smart_folder_rule, field: 'assignee', operator: operator, value: value)
  end

  subject(:filter) { described_class.new(rule) }

  # Tenant must be set before all tenant-scoped creates
  before do
    ActsAsTenant.current_tenant = organisation
  end

  after { ActsAsTenant.current_tenant = nil }

  # Create project and tickets within the tenant context
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket_assigned) { create(:ticket, project: project) }
  let(:ticket_other_assignee) { create(:ticket, project: project) }
  let(:ticket_unassigned) { create(:ticket, project: project) }
  let(:ticket_both_assigned) { create(:ticket, project: project) }

  # Set up assignments — order: tickets must exist
  before do
    # Materialize tickets
    ticket_assigned
    ticket_other_assignee
    ticket_unassigned
    ticket_both_assigned

    create(:ticket_assignment, ticket: ticket_assigned, user: assigned_user)
    create(:ticket_assignment, ticket: ticket_other_assignee, user: other_user)
    create(:ticket_assignment, ticket: ticket_both_assigned, user: assigned_user)
    create(:ticket_assignment, ticket: ticket_both_assigned, user: other_user)
  end

  def result_ids
    filter.apply(Ticket.where(project: project), 'Ticket').pluck(:id)
  end

  describe 'operator: equals' do
    let(:operator) { 'equals' }
    let(:value) { assigned_user.id }

    it 'returns tickets assigned to the user' do
      expect(result_ids).to contain_exactly(ticket_assigned.id, ticket_both_assigned.id)
    end

    it 'excludes unassigned tickets' do
      expect(result_ids).not_to include(ticket_unassigned.id)
    end

    it 'excludes tickets assigned to other users only' do
      expect(result_ids).not_to include(ticket_other_assignee.id)
    end

    it 'does not produce duplicate results for tickets with multiple assignees' do
      ids = filter.apply(Ticket.where(project: project), 'Ticket').pluck(:id)
      expect(ids.size).to eq(ids.uniq.size)
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

    context 'with non-existent user id' do
      let(:value) { SecureRandom.uuid }

      it 'returns no results' do
        expect(result_ids).to be_empty
      end
    end
  end

  describe 'operator: not_equals' do
    let(:operator) { 'not_equals' }
    let(:value) { assigned_user.id }

    it 'returns tickets not assigned to the user' do
      expect(result_ids).to contain_exactly(ticket_other_assignee.id, ticket_unassigned.id)
    end

    it 'includes unassigned tickets' do
      expect(result_ids).to include(ticket_unassigned.id)
    end

    it 'excludes tickets assigned to the user (even with multiple assignees)' do
      expect(result_ids).not_to include(ticket_both_assigned.id)
    end

    context 'with blank value' do
      let(:value) { nil }

      it 'returns all tickets (no filter applied)' do
        expect(result_ids).to contain_exactly(
          ticket_assigned.id, ticket_other_assignee.id,
          ticket_unassigned.id, ticket_both_assigned.id
        )
      end
    end

    context 'with non-existent user id' do
      let(:value) { SecureRandom.uuid }

      it 'returns all tickets (no assignment matches)' do
        expect(result_ids).to contain_exactly(
          ticket_assigned.id, ticket_other_assignee.id,
          ticket_unassigned.id, ticket_both_assigned.id
        )
      end
    end
  end

  describe 'unsupported operator' do
    let(:operator) { 'contains' }
    let(:value) { assigned_user.id }

    before do
      allow(rule).to receive(:id).and_return('test-rule-id')
    end

    it 'returns the query unchanged' do
      expect(result_ids).to contain_exactly(
        ticket_assigned.id, ticket_other_assignee.id,
        ticket_unassigned.id, ticket_both_assigned.id
      )
    end

    it 'logs a warning' do
      allow(Rails.logger).to receive(:warn)
      filter.apply(Ticket.where(project: project), 'Ticket')
      expect(Rails.logger).to have_received(:warn).with(/Unsupported assignee operator 'contains'/)
    end
  end

  describe 'non-Ticket model' do
    let(:operator) { 'equals' }
    let(:value) { assigned_user.id }

    it 'returns the query unchanged for Note queries' do
      note_query = Note.where(project: project)
      result = filter.apply(note_query, 'Note')
      expect(result).to eq(note_query)
    end
  end

  describe 'edge cases' do
    let(:operator) { 'equals' }
    let(:value) { assigned_user.id }

    context 'with an empty tickets table (no matches in scope)' do
      it 'returns empty relation' do
        other_project = create(:project, organisation: organisation)
        ids = filter.apply(Ticket.where(project: other_project), 'Ticket').pluck(:id)
        expect(ids).to be_empty
      end
    end

    context 'when the same user is assigned multiple times (DB constraint prevents this)' do
      it 'rejects duplicate assignments at DB level' do
        expect do
          create(:ticket_assignment, ticket: ticket_assigned, user: assigned_user)
        end.to raise_error(ActiveRecord::RecordNotUnique)
      end
    end
  end
end
