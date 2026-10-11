# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SmartFolders::Filters::CustomAttributeFilter, type: :model do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  let(:rule) do
    build_stubbed(:smart_folder_rule, field: field, operator: operator, value: value)
  end

  subject(:filter) { described_class.new(rule) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:field) { 'custom_category' }
  let(:base_query) { Ticket.where(project: project) }

  def result_ids
    filter.apply(base_query, 'Ticket').pluck(:id)
  end

  # ── Testdaten ───────────────────────────────────────────────────────

  let!(:ticket_bug) do
    create(:ticket, project: project, custom_attributes: { 'category' => 'Bug', 'priority' => '3', 'active' => true })
  end
  let!(:ticket_feature) do
    create(:ticket, project: project, custom_attributes: { 'category' => 'Feature', 'priority' => '7', 'active' => false })
  end
  let!(:ticket_bugfix) do
    create(:ticket, project: project, custom_attributes: { 'category' => 'Bugfix', 'priority' => '5' })
  end
  let!(:ticket_empty_category) do
    create(:ticket, project: project, custom_attributes: { 'category' => '' })
  end
  let!(:ticket_no_category) do
    create(:ticket, project: project, custom_attributes: { 'other' => 'value' })
  end
  let!(:ticket_empty_attrs) do
    create(:ticket, project: project, custom_attributes: {})
  end

  def all_ticket_ids
    [ticket_bug, ticket_feature, ticket_bugfix, ticket_empty_category, ticket_no_category, ticket_empty_attrs].map(&:id)
  end

  # ══════════════════════════════════════════════════════════════════════
  # Containment Operators
  # ══════════════════════════════════════════════════════════════════════

  describe 'operator: equals' do
    let(:operator) { 'equals' }
    let(:value) { 'Bug' }

    it 'returns tickets with exact attribute match' do
      expect(result_ids).to contain_exactly(ticket_bug.id)
    end

    it 'excludes tickets with different values' do
      expect(result_ids).not_to include(ticket_feature.id, ticket_bugfix.id)
    end

    it 'excludes tickets without the attribute' do
      expect(result_ids).not_to include(ticket_no_category.id, ticket_empty_attrs.id)
    end

    context 'with nil value' do
      let(:value) { nil }

      it 'returns query unchanged' do
        expect(result_ids).to contain_exactly(*all_ticket_ids)
      end
    end
  end

  describe 'operator: not_equals' do
    let(:operator) { 'not_equals' }
    let(:value) { 'Bug' }

    it 'returns tickets that do not match' do
      expect(result_ids).to include(ticket_feature.id, ticket_bugfix.id)
    end

    it 'includes tickets without the attribute' do
      expect(result_ids).to include(ticket_no_category.id, ticket_empty_attrs.id)
    end

    it 'excludes the matching ticket' do
      expect(result_ids).not_to include(ticket_bug.id)
    end

    context 'with nil value' do
      let(:value) { nil }

      it 'returns query unchanged' do
        expect(result_ids).to contain_exactly(*all_ticket_ids)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Text Operators
  # ══════════════════════════════════════════════════════════════════════

  describe 'operator: contains' do
    let(:operator) { 'contains' }
    let(:value) { 'Bug' }

    it 'matches substring' do
      expect(result_ids).to contain_exactly(ticket_bug.id, ticket_bugfix.id)
    end

    it 'is case-insensitive' do
      rule_lower = build_stubbed(:smart_folder_rule, field: 'custom_category', operator: 'contains', value: 'bug')
      ids = described_class.new(rule_lower).apply(base_query, 'Ticket').pluck(:id)
      expect(ids).to contain_exactly(ticket_bug.id, ticket_bugfix.id)
    end

    context 'with LIKE special characters' do
      let(:value) { '100%' }

      it 'escapes percent sign and does not match unintended rows' do
        ticket_with_percent = create(:ticket, project: project, custom_attributes: { 'category' => '100% done' })
        create(:ticket, project: project, custom_attributes: { 'category' => '100 things' })
        expect(result_ids).to contain_exactly(ticket_with_percent.id)
      end
    end

    context 'with underscore in value' do
      let(:value) { 'a_b' }

      it 'escapes underscore and matches literally' do
        ticket_match = create(:ticket, project: project, custom_attributes: { 'category' => 'a_b_c' })
        create(:ticket, project: project, custom_attributes: { 'category' => 'axbxc' })
        expect(result_ids).to contain_exactly(ticket_match.id)
      end
    end

    context 'with nil value' do
      let(:value) { nil }

      it 'returns query unchanged' do
        expect(result_ids).to contain_exactly(*all_ticket_ids)
      end
    end
  end

  describe 'operator: not_contains' do
    let(:operator) { 'not_contains' }
    let(:value) { 'Bug' }

    it 'excludes tickets containing the substring' do
      expect(result_ids).not_to include(ticket_bug.id, ticket_bugfix.id)
    end

    it 'includes tickets without the attribute (NULL)' do
      expect(result_ids).to include(ticket_no_category.id, ticket_empty_attrs.id)
    end

    context 'with nil value' do
      let(:value) { nil }

      it 'returns query unchanged' do
        expect(result_ids).to contain_exactly(*all_ticket_ids)
      end
    end
  end

  describe 'operator: starts_with' do
    let(:operator) { 'starts_with' }
    let(:value) { 'Bug' }

    it 'matches values starting with the string' do
      expect(result_ids).to contain_exactly(ticket_bug.id, ticket_bugfix.id)
    end

    it 'does not match values that only contain the string' do
      ticket_postfix = create(:ticket, project: project, custom_attributes: { 'category' => 'MyBug' })
      expect(result_ids).not_to include(ticket_postfix.id)
    end

    context 'with nil value' do
      let(:value) { nil }

      it 'returns query unchanged' do
        expect(result_ids).to contain_exactly(*all_ticket_ids)
      end
    end
  end

  describe 'operator: ends_with' do
    let(:operator) { 'ends_with' }
    let(:value) { 'fix' }

    it 'matches values ending with the string' do
      expect(result_ids).to contain_exactly(ticket_bugfix.id)
    end

    it 'does not match values that only contain the string elsewhere' do
      expect(result_ids).not_to include(ticket_bug.id, ticket_feature.id)
    end

    context 'with nil value' do
      let(:value) { nil }

      it 'returns query unchanged' do
        expect(result_ids).to contain_exactly(*all_ticket_ids)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Numeric Operators
  # ══════════════════════════════════════════════════════════════════════

  describe 'operator: greater_than' do
    let(:field) { 'custom_priority' }
    let(:operator) { 'greater_than' }
    let(:value) { '4' }

    it 'returns tickets with numeric value greater than threshold' do
      expect(result_ids).to contain_exactly(ticket_feature.id, ticket_bugfix.id)
    end

    it 'excludes tickets with value less than or equal to threshold' do
      expect(result_ids).not_to include(ticket_bug.id)
    end

    context 'with nil value' do
      let(:value) { nil }

      it 'returns query unchanged' do
        expect(result_ids).to contain_exactly(*all_ticket_ids)
      end
    end
  end

  describe 'operator: less_than' do
    let(:field) { 'custom_priority' }
    let(:operator) { 'less_than' }
    let(:value) { '5' }

    it 'returns tickets with numeric value less than threshold' do
      expect(result_ids).to contain_exactly(ticket_bug.id)
    end

    it 'excludes tickets with value greater than or equal to threshold' do
      expect(result_ids).not_to include(ticket_feature.id, ticket_bugfix.id)
    end

    context 'with nil value' do
      let(:value) { nil }

      it 'returns query unchanged' do
        expect(result_ids).to contain_exactly(*all_ticket_ids)
      end
    end
  end

  describe 'operator: between' do
    let(:field) { 'custom_priority' }
    let(:operator) { 'between' }
    let(:value) { '4,6' }

    it 'returns tickets within the inclusive range' do
      expect(result_ids).to contain_exactly(ticket_bugfix.id)
    end

    it 'excludes tickets outside the range' do
      expect(result_ids).not_to include(ticket_bug.id, ticket_feature.id)
    end

    context 'with inclusive boundary values' do
      let(:value) { '3,7' }

      it 'includes tickets at both boundaries' do
        expect(result_ids).to contain_exactly(ticket_bug.id, ticket_feature.id, ticket_bugfix.id)
      end
    end

    context 'with reversed order (max,min)' do
      let(:value) { '6,4' }

      it 'auto-sorts and returns correct results' do
        expect(result_ids).to contain_exactly(ticket_bugfix.id)
      end
    end

    context 'with only one value (invalid)' do
      let(:value) { '5' }

      it 'returns query unchanged' do
        expect(result_ids).to contain_exactly(*all_ticket_ids)
      end

      it 'logs a warning' do
        allow(Rails.logger).to receive(:warn)
        filter.apply(base_query, 'Ticket')
        expect(Rails.logger).to have_received(:warn).with(/Invalid between value/)
      end
    end

    context 'with three values (invalid)' do
      let(:value) { '1,5,10' }

      it 'returns query unchanged' do
        expect(result_ids).to contain_exactly(*all_ticket_ids)
      end
    end

    context 'with nil value' do
      let(:value) { nil }

      it 'returns query unchanged' do
        expect(result_ids).to contain_exactly(*all_ticket_ids)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Presence Operators
  # ══════════════════════════════════════════════════════════════════════

  describe 'operator: is_empty' do
    let(:operator) { 'is_empty' }
    let(:value) { nil }

    it 'returns tickets where attribute is missing or empty string' do
      expect(result_ids).to contain_exactly(ticket_empty_category.id, ticket_no_category.id, ticket_empty_attrs.id)
    end

    it 'excludes tickets with a non-empty value' do
      expect(result_ids).not_to include(ticket_bug.id, ticket_feature.id, ticket_bugfix.id)
    end
  end

  describe 'operator: is_blank' do
    let(:operator) { 'is_blank' }
    let(:value) { nil }

    it 'behaves the same as is_empty' do
      expect(result_ids).to contain_exactly(ticket_empty_category.id, ticket_no_category.id, ticket_empty_attrs.id)
    end
  end

  describe 'operator: is_not_empty' do
    let(:operator) { 'is_not_empty' }
    let(:value) { nil }

    it 'returns tickets with a non-empty attribute value' do
      expect(result_ids).to contain_exactly(ticket_bug.id, ticket_feature.id, ticket_bugfix.id)
    end

    it 'excludes tickets with missing or empty attribute' do
      expect(result_ids).not_to include(ticket_empty_category.id, ticket_no_category.id, ticket_empty_attrs.id)
    end
  end

  describe 'operator: is_not_blank' do
    let(:operator) { 'is_not_blank' }
    let(:value) { nil }

    it 'behaves the same as is_not_empty' do
      expect(result_ids).to contain_exactly(ticket_bug.id, ticket_feature.id, ticket_bugfix.id)
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Boolean Operators
  # ══════════════════════════════════════════════════════════════════════

  describe 'operator: is_true' do
    let(:field) { 'custom_active' }
    let(:operator) { 'is_true' }
    let(:value) { nil }

    it 'returns tickets where the attribute is true' do
      expect(result_ids).to contain_exactly(ticket_bug.id)
    end

    it 'excludes tickets where the attribute is false' do
      expect(result_ids).not_to include(ticket_feature.id)
    end

    it 'excludes tickets without the attribute' do
      expect(result_ids).not_to include(ticket_bugfix.id, ticket_no_category.id)
    end
  end

  describe 'operator: is (alias for is_true)' do
    let(:field) { 'custom_active' }
    let(:operator) { 'is' }
    let(:value) { nil }

    it 'returns tickets where the attribute is true' do
      expect(result_ids).to contain_exactly(ticket_bug.id)
    end
  end

  describe 'operator: is_false' do
    let(:field) { 'custom_active' }
    let(:operator) { 'is_false' }
    let(:value) { nil }

    it 'returns tickets where the attribute is false' do
      expect(result_ids).to contain_exactly(ticket_feature.id)
    end

    it 'excludes tickets where the attribute is true' do
      expect(result_ids).not_to include(ticket_bug.id)
    end

    it 'excludes tickets without the attribute' do
      expect(result_ids).not_to include(ticket_bugfix.id, ticket_no_category.id)
    end
  end

  describe 'operator: is_not (alias for is_false)' do
    let(:field) { 'custom_active' }
    let(:operator) { 'is_not' }
    let(:value) { nil }

    it 'returns tickets where the attribute is false' do
      expect(result_ids).to contain_exactly(ticket_feature.id)
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # List Operators
  # ══════════════════════════════════════════════════════════════════════

  describe 'operator: in_list' do
    let(:operator) { 'in_list' }
    let(:value) { 'Bug,Feature' }

    it 'returns tickets matching any value in the list' do
      expect(result_ids).to contain_exactly(ticket_bug.id, ticket_feature.id)
    end

    it 'handles whitespace around commas' do
      rule_ws = build_stubbed(:smart_folder_rule, field: 'custom_category', operator: 'in_list', value: ' Bug , Feature ')
      ids = described_class.new(rule_ws).apply(base_query, 'Ticket').pluck(:id)
      expect(ids).to contain_exactly(ticket_bug.id, ticket_feature.id)
    end

    context 'with nil value' do
      let(:value) { nil }

      it 'returns query unchanged' do
        expect(result_ids).to contain_exactly(*all_ticket_ids)
      end
    end
  end

  describe 'operator: not_in_list' do
    let(:operator) { 'not_in_list' }
    let(:value) { 'Bug,Feature' }

    it 'excludes tickets matching any value in the list' do
      expect(result_ids).not_to include(ticket_bug.id, ticket_feature.id)
    end

    it 'includes tickets with other values' do
      expect(result_ids).to include(ticket_bugfix.id)
    end

    context 'with nil value' do
      let(:value) { nil }

      it 'returns query unchanged' do
        expect(result_ids).to contain_exactly(*all_ticket_ids)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Edge Cases
  # ══════════════════════════════════════════════════════════════════════

  describe 'non-Ticket item_type' do
    let(:operator) { 'equals' }
    let(:value) { 'Bug' }

    it 'returns query unchanged for non-Ticket models' do
      note_query = Note.where(project: project)
      result = filter.apply(note_query, 'Note')
      expect(result).to eq(note_query)
    end
  end

  describe 'field without custom_ prefix' do
    let(:field) { 'category' }
    let(:operator) { 'equals' }
    let(:value) { 'Bug' }

    it 'returns query unchanged' do
      expect(result_ids).to contain_exactly(*all_ticket_ids)
    end
  end

  describe 'unknown operator' do
    let(:operator) { 'matches_regex' }
    let(:value) { '.*' }

    it 'returns query unchanged' do
      expect(result_ids).to contain_exactly(*all_ticket_ids)
    end

    it 'logs a warning' do
      allow(Rails.logger).to receive(:warn)
      filter.apply(base_query, 'Ticket')
      expect(Rails.logger).to have_received(:warn).with(/Unknown operator 'matches_regex'/)
    end
  end

  describe 'empty ticket set' do
    let(:operator) { 'equals' }
    let(:value) { 'Bug' }

    it 'returns empty result when no tickets in scope' do
      other_project = create(:project, organisation: organisation)
      ids = filter.apply(Ticket.where(project: other_project), 'Ticket').pluck(:id)
      expect(ids).to be_empty
    end
  end

  describe 'extract_attribute_name with custom_ in attribute name' do
    let(:field) { 'custom_custom_field' }
    let(:operator) { 'equals' }
    let(:value) { 'test' }

    it 'only strips the prefix, not all occurrences of custom_' do
      ticket = create(:ticket, project: project, custom_attributes: { 'custom_field' => 'test' })
      expect(result_ids).to contain_exactly(ticket.id)
    end
  end
end
