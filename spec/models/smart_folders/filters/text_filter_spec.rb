# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SmartFolders::Filters::TextFilter, type: :model do
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

  def build_rule(field:, operator:, value:)
    create(:smart_folder_rule,
           smart_folder_rule_group: rule_group,
           field: field, operator: operator, value: value)
  end

  # Bypass variant: create the rule with a valid field, then override the field
  def build_rule_bypassing_validation(field:, operator:, value:)
    rule = build_rule(field: 'title', operator: operator, value: value.presence || 'placeholder')
    rule.update_column(:field, field) if field != 'title'
    rule.update_column(:value, value) if value != rule.value
    rule.reload
  end

  def apply_filter(rule, query: Ticket.all, item_type: 'Ticket')
    described_class.new(rule).apply(query, item_type)
  end

  # Prosopite-safe assertion helper: checks IDs instead of include (avoids N+1 on existence checks)
  def expect_ids(relation, included: [], excluded: [])
    ids = relation.pluck(:id)
    included.each { |record| expect(ids).to include(record.id) }
    excluded.each { |record| expect(ids).not_to include(record.id) }
  end

  # -- Test data (title = NOT NULL, summary = nullable) -------------------

  let!(:ticket_hello) do
    create(:ticket, project: project, organisation: organisation,
                    title: 'Hello World', summary: 'A greeting ticket')
  end

  let!(:ticket_goodbye) do
    create(:ticket, project: project, organisation: organisation,
                    title: 'Goodbye Cruel World', summary: 'A farewell ticket')
  end

  let!(:ticket_empty_title) do
    ticket = create(:ticket, project: project, organisation: organisation, title: 'placeholder')
    ticket.update_column(:title, '')
    ticket
  end

  let!(:ticket_nil_summary) do
    create(:ticket, project: project, organisation: organisation,
                    title: 'No Summary', summary: nil)
  end

  # == Operator: contains =================================================

  describe "operator 'contains'" do
    it 'matches tickets containing the search term (case-insensitive via ILIKE)' do
      rule = build_rule(field: 'title', operator: 'contains', value: 'hello')
      result = apply_filter(rule)

      expect_ids(result, included: [ticket_hello], excluded: [ticket_goodbye])
    end

    it 'matches partial strings' do
      rule = build_rule(field: 'title', operator: 'contains', value: 'World')
      result = apply_filter(rule)

      expect_ids(result, included: [ticket_hello, ticket_goodbye], excluded: [ticket_empty_title])
    end

    it 'does not match NULL values on nullable column' do
      rule = build_rule_bypassing_validation(field: 'summary', operator: 'contains', value: 'anything')
      result = apply_filter(rule)

      expect_ids(result, excluded: [ticket_nil_summary])
    end

    it 'matches all non-NULL when searching for empty string' do
      rule = build_rule(field: 'title', operator: 'contains', value: 'x')
      rule.update_column(:value, '')
      rule.reload

      result = apply_filter(rule)

      # LIKE '%%' matches all non-NULL strings
      expect_ids(result, included: [ticket_hello, ticket_goodbye, ticket_empty_title, ticket_nil_summary])
    end
  end

  # == Operator: not_contains =============================================

  describe "operator 'not_contains'" do
    it 'excludes tickets containing the term' do
      rule = build_rule(field: 'title', operator: 'not_contains', value: 'Hello')
      result = apply_filter(rule)

      expect_ids(result, included: [ticket_goodbye], excluded: [ticket_hello])
    end

    it 'includes NULL values (NULL does not "contain" anything)' do
      rule = build_rule_bypassing_validation(field: 'summary', operator: 'not_contains', value: 'greeting')
      result = apply_filter(rule)

      expect_ids(result, included: [ticket_nil_summary])
    end

    it 'includes empty strings that do not contain the term' do
      rule = build_rule(field: 'title', operator: 'not_contains', value: 'xyz')
      result = apply_filter(rule)

      expect_ids(result, included: [ticket_empty_title])
    end
  end

  # == Operator: equals ===================================================

  describe "operator 'equals'" do
    it 'matches exact value (case-insensitive)' do
      rule = build_rule(field: 'title', operator: 'equals', value: 'hello world')
      result = apply_filter(rule)

      expect_ids(result, included: [ticket_hello], excluded: [ticket_goodbye])
    end

    it 'is case-insensitive' do
      rule = build_rule(field: 'title', operator: 'equals', value: 'HELLO WORLD')
      result = apply_filter(rule)

      expect_ids(result, included: [ticket_hello])
    end

    it 'does not match partial strings' do
      rule = build_rule(field: 'title', operator: 'equals', value: 'Hello')
      result = apply_filter(rule)

      expect_ids(result, excluded: [ticket_hello])
    end

    it 'matches empty string exactly' do
      rule = build_rule(field: 'title', operator: 'equals', value: 'x')
      rule.update_column(:value, '')
      rule.reload

      result = apply_filter(rule)

      expect_ids(result, included: [ticket_empty_title], excluded: [ticket_hello])
    end

    it 'does not match NULL values' do
      rule = build_rule_bypassing_validation(field: 'summary', operator: 'equals', value: 'A greeting ticket')
      result = apply_filter(rule)

      expect_ids(result, included: [ticket_hello], excluded: [ticket_nil_summary])
    end
  end

  # == Operator: not_equals ===============================================

  describe "operator 'not_equals'" do
    it 'excludes exact matches (case-insensitive)' do
      rule = build_rule(field: 'title', operator: 'not_equals', value: 'Hello World')
      result = apply_filter(rule)

      expect_ids(result, included: [ticket_goodbye], excluded: [ticket_hello])
    end

    it 'includes NULL values' do
      rule = build_rule_bypassing_validation(field: 'summary', operator: 'not_equals', value: 'A greeting ticket')
      result = apply_filter(rule)

      expect_ids(result, included: [ticket_nil_summary])
    end

    it 'includes empty strings when value is non-empty' do
      rule = build_rule(field: 'title', operator: 'not_equals', value: 'Hello World')
      result = apply_filter(rule)

      expect_ids(result, included: [ticket_empty_title])
    end
  end

  # == Operator: starts_with ==============================================

  describe "operator 'starts_with'" do
    it 'matches tickets whose title starts with the value' do
      rule = build_rule(field: 'title', operator: 'starts_with', value: 'Hello')
      result = apply_filter(rule)

      expect_ids(result, included: [ticket_hello], excluded: [ticket_goodbye])
    end

    it 'does not match mid-string occurrences' do
      rule = build_rule(field: 'title', operator: 'starts_with', value: 'World')
      result = apply_filter(rule)

      expect_ids(result, excluded: [ticket_hello])
    end

    it 'does not match NULL values' do
      rule = build_rule_bypassing_validation(field: 'summary', operator: 'starts_with', value: 'A')
      result = apply_filter(rule)

      expect_ids(result, excluded: [ticket_nil_summary])
    end
  end

  # == Operator: ends_with ================================================

  describe "operator 'ends_with'" do
    it 'matches tickets whose title ends with the value' do
      rule = build_rule(field: 'title', operator: 'ends_with', value: 'World')
      result = apply_filter(rule)

      expect_ids(result, included: [ticket_hello, ticket_goodbye])
    end

    it 'does not match if value occurs only at the beginning' do
      rule = build_rule(field: 'title', operator: 'ends_with', value: 'Hello')
      result = apply_filter(rule)

      expect_ids(result, excluded: [ticket_hello])
    end

    it 'does not match NULL values' do
      rule = build_rule_bypassing_validation(field: 'summary', operator: 'ends_with', value: 'ticket')
      result = apply_filter(rule)

      expect_ids(result, excluded: [ticket_nil_summary])
    end
  end

  # == Edge Cases =========================================================

  describe 'SQL injection / LIKE special characters' do
    it 'escapes % in the search value' do
      ticket_pct = create(:ticket, project: project, organisation: organisation, title: '100% done')
      rule = build_rule(field: 'title', operator: 'contains', value: '100%')
      result = apply_filter(rule)

      expect_ids(result, included: [ticket_pct], excluded: [ticket_hello])
    end

    it 'escapes _ in the search value' do
      ticket_underscore = create(:ticket, project: project, organisation: organisation, title: 'hello_world')
      rule = build_rule(field: 'title', operator: 'contains', value: 'o_w')
      result = apply_filter(rule)

      expect_ids(result, included: [ticket_underscore], excluded: [ticket_hello])
    end

    it 'escapes backslash in the search value' do
      ticket_bs = create(:ticket, project: project, organisation: organisation, title: 'path\\to\\file')
      rule = build_rule(field: 'title', operator: 'contains', value: '\\to\\')
      result = apply_filter(rule)

      expect_ids(result, included: [ticket_bs], excluded: [ticket_hello])
    end
  end

  describe 'unknown column' do
    it 'returns empty relation and logs warning' do
      rule = build_rule(field: 'title', operator: 'contains', value: 'test')
      rule.update_column(:field, 'nonexistent_column')
      rule.reload

      expect(Rails.logger).to receive(:warn).with(/not found for model/)
      result = apply_filter(rule)

      expect(result).to be_empty
      expect(result).to be_a(ActiveRecord::Relation)
    end
  end

  describe 'unsupported operator' do
    it 'returns query unchanged and logs warning' do
      rule = build_rule(field: 'title', operator: 'contains', value: 'test')
      rule.update_column(:operator, 'regex_match')
      rule.reload

      expect(Rails.logger).to receive(:warn).with(/Unsupported text operator 'regex_match'/)
      result = apply_filter(rule)

      expect(result.to_sql).to eq(Ticket.all.to_sql)
    end
  end

  describe 'nil rule value' do
    it 'treats nil value as empty string for contains (matches all non-NULL)' do
      rule = build_rule(field: 'title', operator: 'contains', value: 'x')
      rule.update_column(:value, nil)
      rule.reload

      result = apply_filter(rule)

      # nil.to_s => "" => LIKE '%%' matches all non-NULL
      expect_ids(result, included: [ticket_hello, ticket_goodbye, ticket_empty_title, ticket_nil_summary])
    end

    it 'treats nil value as empty string for equals' do
      rule = build_rule(field: 'title', operator: 'equals', value: 'x')
      rule.update_column(:value, nil)
      rule.reload

      result = apply_filter(rule)

      # LOWER(title) = '' matches only empty title
      expect_ids(result, included: [ticket_empty_title], excluded: [ticket_hello])
    end
  end

  describe 'empty dataset' do
    before { Ticket.delete_all }

    it 'returns empty relation without errors' do
      rule = build_rule(field: 'title', operator: 'contains', value: 'anything')
      result = apply_filter(rule)

      expect(result).to be_empty
      expect(result).to be_a(ActiveRecord::Relation)
    end
  end

  describe 'whitespace handling' do
    it 'preserves leading/trailing whitespace in search' do
      ticket_spaced = create(:ticket, project: project, organisation: organisation, title: '  spaced  ')
      rule = build_rule(field: 'title', operator: 'equals', value: '  spaced  ')
      result = apply_filter(rule)

      expect_ids(result, included: [ticket_spaced])
    end

    it 'does not trim whitespace (exact match requires it)' do
      ticket_spaced = create(:ticket, project: project, organisation: organisation, title: '  spaced  ')
      rule = build_rule(field: 'title', operator: 'equals', value: 'spaced')
      result = apply_filter(rule)

      expect_ids(result, excluded: [ticket_spaced])
    end
  end

  describe 'unicode support' do
    it 'matches unicode characters with contains (same case)' do
      ticket_unicode = create(:ticket, project: project, organisation: organisation, title: 'Ünïcödé Tëst')
      rule = build_rule(field: 'title', operator: 'contains', value: 'Ünïcödé')
      result = apply_filter(rule)

      expect_ids(result, included: [ticket_unicode])
    end

    it 'matches German umlauts with contains (same case)' do
      ticket_umlaut = create(:ticket, project: project, organisation: organisation, title: 'Über uns')
      rule = build_rule(field: 'title', operator: 'contains', value: 'Über')
      result = apply_filter(rule)

      expect_ids(result, included: [ticket_umlaut])
    end

    it 'matches German umlauts with equals (same case)' do
      ticket_umlaut = create(:ticket, project: project, organisation: organisation, title: 'über uns')
      rule = build_rule(field: 'title', operator: 'equals', value: 'über uns')
      result = apply_filter(rule)

      expect_ids(result, included: [ticket_umlaut])
    end
  end
end
