# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SmartFolders::Filters::HasTimeSessionsFilter, type: :model do
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

  def build_rule(operator:, value:)
    create(:smart_folder_rule,
           smart_folder_rule_group: rule_group,
           field: 'has_time_sessions', operator: operator, value: value)
  end

  def apply_filter(rule, query: Ticket.where(project: project), item_type: 'Ticket')
    described_class.new(rule).apply(query, item_type)
  end

  def result_ids(rule, **opts)
    apply_filter(rule, **opts).pluck(:id)
  end

  # -- Test data ----------------------------------------------------------

  let!(:ticket_with_sessions) { create(:ticket, project: project) }
  let!(:ticket_without_sessions) { create(:ticket, project: project) }
  let!(:ticket_multiple_sessions) { create(:ticket, project: project) }

  before do
    create(:time_session, ticket: ticket_with_sessions, project: project, organisation: organisation)
    create(:time_session, ticket: ticket_multiple_sessions, project: project, organisation: organisation)
    create(:time_session, ticket: ticket_multiple_sessions, project: project, organisation: organisation)
  end

  # -- operator: is -------------------------------------------------------

  describe "operator 'is'" do
    context "with value 'true'" do
      let(:rule) { build_rule(operator: 'is', value: 'true') }

      it 'returns only tickets that have time sessions' do
        expect(result_ids(rule)).to contain_exactly(
          ticket_with_sessions.id, ticket_multiple_sessions.id
        )
      end

      it 'excludes tickets without time sessions' do
        expect(result_ids(rule)).not_to include(ticket_without_sessions.id)
      end
    end

    context "with value 'false'" do
      let(:rule) { build_rule(operator: 'is', value: 'false') }

      it 'returns only tickets without time sessions' do
        expect(result_ids(rule)).to contain_exactly(ticket_without_sessions.id)
      end

      it 'excludes tickets with time sessions' do
        expect(result_ids(rule)).not_to include(
          ticket_with_sessions.id, ticket_multiple_sessions.id
        )
      end
    end
  end

  # -- operator: is_not ---------------------------------------------------

  describe "operator 'is_not'" do
    context "with value 'true' (= tickets WITHOUT sessions)" do
      let(:rule) { build_rule(operator: 'is_not', value: 'true') }

      it 'returns tickets without time sessions' do
        expect(result_ids(rule)).to contain_exactly(ticket_without_sessions.id)
      end
    end

    context "with value 'false' (= tickets WITH sessions)" do
      let(:rule) { build_rule(operator: 'is_not', value: 'false') }

      it 'returns tickets with time sessions' do
        expect(result_ids(rule)).to contain_exactly(
          ticket_with_sessions.id, ticket_multiple_sessions.id
        )
      end
    end
  end

  # -- Symmetry: is+false == is_not+true ----------------------------------

  describe 'operator symmetry' do
    it "'is' false produces the same SQL as 'is_not' true" do
      is_false = build_rule(operator: 'is', value: 'false')
      is_not_true = build_rule(operator: 'is_not', value: 'true')

      sql_a = apply_filter(is_false).to_sql
      sql_b = apply_filter(is_not_true).to_sql

      expect(sql_a).to eq(sql_b)
    end

    it "'is' true produces the same SQL as 'is_not' false" do
      is_true = build_rule(operator: 'is', value: 'true')
      is_not_false = build_rule(operator: 'is_not', value: 'false')

      sql_a = apply_filter(is_true).to_sql
      sql_b = apply_filter(is_not_false).to_sql

      expect(sql_a).to eq(sql_b)
    end
  end

  # -- Duplicates ---------------------------------------------------------

  describe 'no duplicates' do
    it 'does not produce duplicate results for tickets with multiple time sessions' do
      rule = build_rule(operator: 'is', value: 'true')
      ids = result_ids(rule)

      expect(ids.size).to eq(ids.uniq.size)
    end
  end

  # -- Soft-Deleted Time Sessions -----------------------------------------

  describe 'soft-deleted time sessions' do
    let!(:ticket_only_deleted_sessions) { create(:ticket, project: project) }

    before do
      ts = create(:time_session, ticket: ticket_only_deleted_sessions,
                                 project: project, organisation: organisation)
      ts.update_column(:deleted_at, Time.current)
    end

    it "treats ticket with only soft-deleted sessions as having no sessions (operator 'is' true)" do
      rule = build_rule(operator: 'is', value: 'true')

      expect(result_ids(rule)).not_to include(ticket_only_deleted_sessions.id)
    end

    it "includes ticket with only soft-deleted sessions when filtering for no sessions (operator 'is' false)" do
      rule = build_rule(operator: 'is', value: 'false')

      expect(result_ids(rule)).to include(ticket_only_deleted_sessions.id)
    end

    context 'when ticket has both active and soft-deleted sessions' do
      before do
        create(:time_session, ticket: ticket_only_deleted_sessions,
                              project: project, organisation: organisation)
      end

      it 'still counts the ticket as having sessions' do
        rule = build_rule(operator: 'is', value: 'true')

        expect(result_ids(rule)).to include(ticket_only_deleted_sessions.id)
      end
    end
  end

  # -- Non-Ticket item_type -----------------------------------------------

  describe 'non-Ticket item_type' do
    it 'returns the query unchanged for non-Ticket types' do
      rule = build_rule(operator: 'is', value: 'true')
      query = Ticket.where(project: project)

      result = apply_filter(rule, query: query, item_type: 'Note')

      expect(result.to_sql).to eq(query.to_sql)
    end

    it 'returns the query unchanged for TimeSession type' do
      rule = build_rule(operator: 'is', value: 'true')
      query = Ticket.where(project: project)

      result = apply_filter(rule, query: query, item_type: 'TimeSession')

      expect(result.to_sql).to eq(query.to_sql)
    end
  end

  # -- Unsupported Operator -----------------------------------------------

  describe 'unsupported operator' do
    it 'returns the query unchanged' do
      rule = build_rule(operator: 'is', value: 'true')
      rule.update_column(:operator, 'contains')
      rule.reload

      query = Ticket.where(project: project)
      result = apply_filter(rule)

      expect(result.to_sql).to eq(query.to_sql)
    end

    it 'logs a warning' do
      rule = build_rule(operator: 'is', value: 'true')
      rule.update_column(:operator, 'greater_than')
      rule.reload

      expect(Rails.logger).to receive(:warn).with(/Unsupported operator 'greater_than'/)

      apply_filter(rule)
    end
  end

  # -- Truthy/Falsy Value Coercion ----------------------------------------

  describe 'value coercion' do
    %w[true 1].each do |truthy_val|
      it "treats '#{truthy_val}' as truthy" do
        rule = build_rule(operator: 'is', value: 'true')
        rule.update_column(:value, truthy_val)
        rule.reload

        expect(result_ids(rule)).to contain_exactly(
          ticket_with_sessions.id, ticket_multiple_sessions.id
        )
      end
    end

    ['false', '0', nil].each do |falsy_val|
      it "treats #{falsy_val.inspect} as falsy" do
        rule = build_rule(operator: 'is', value: 'true')
        rule.update_column(:value, falsy_val)
        rule.reload

        expect(result_ids(rule)).to contain_exactly(ticket_without_sessions.id)
      end
    end

    it 'treats an arbitrary string as falsy' do
      rule = build_rule(operator: 'is', value: 'true')
      rule.update_column(:value, 'maybe')
      rule.reload

      expect(result_ids(rule)).to contain_exactly(ticket_without_sessions.id)
    end
  end

  # -- Empty result set ---------------------------------------------------

  describe 'empty result set' do
    it 'returns empty relation when no tickets exist in scope' do
      rule = build_rule(operator: 'is', value: 'true')
      other_project = create(:project, organisation: organisation)

      result = apply_filter(rule, query: Ticket.where(project: other_project))

      expect(result).to be_empty
      expect(result).to be_a(ActiveRecord::Relation)
    end
  end

  # -- All tickets have / have no sessions --------------------------------

  describe 'boundary: all or none have sessions' do
    context 'when all tickets have time sessions' do
      before do
        create(:time_session, ticket: ticket_without_sessions,
                              project: project, organisation: organisation)
      end

      it "returns all tickets with operator 'is' true" do
        rule = build_rule(operator: 'is', value: 'true')

        expect(result_ids(rule)).to contain_exactly(
          ticket_with_sessions.id, ticket_without_sessions.id, ticket_multiple_sessions.id
        )
      end

      it "returns no tickets with operator 'is' false" do
        rule = build_rule(operator: 'is', value: 'false')

        expect(result_ids(rule)).to be_empty
      end
    end

    context 'when no tickets have time sessions' do
      before { TimeSession.update_all(deleted_at: Time.current) }

      it "returns no tickets with operator 'is' true" do
        rule = build_rule(operator: 'is', value: 'true')

        expect(result_ids(rule)).to be_empty
      end

      it "returns all tickets with operator 'is' false" do
        rule = build_rule(operator: 'is', value: 'false')

        expect(result_ids(rule)).to contain_exactly(
          ticket_with_sessions.id, ticket_without_sessions.id, ticket_multiple_sessions.id
        )
      end
    end
  end

  # -- Chainability: filter on a pre-filtered query -----------------------

  describe 'chainability with pre-filtered queries' do
    it 'works with a pre-scoped query' do
      rule = build_rule(operator: 'is', value: 'true')
      scoped = Ticket.where(project: project, id: [ticket_with_sessions.id, ticket_without_sessions.id])

      expect(result_ids(rule, query: scoped)).to contain_exactly(ticket_with_sessions.id)
    end
  end
end
