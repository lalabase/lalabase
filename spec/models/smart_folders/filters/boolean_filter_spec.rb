# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SmartFolders::Filters::BooleanFilter, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  let(:smart_folder) do
    create(:smart_folder, organisation: organisation, user: user, project: project,
                          target_object_type: 'TimeSession')
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

  def apply_filter(rule, query: TimeSession.all, item_type: 'TimeSession')
    described_class.new(rule).apply(query, item_type)
  end

  # -- Test data --------------------------------------------------------

  let!(:billed_session) do
    create(:time_session, project: project, organisation: organisation,
                          billed_at: 2.days.ago)
  end

  let!(:unbilled_session) do
    create(:time_session, project: project, organisation: organisation,
                          billed_at: nil)
  end

  # -- billed: operator 'is' -------------------------------------------

  describe "field 'billed', operator 'is'" do
    it "filters billed sessions (value 'true')" do
      rule = build_rule(field: 'billed', operator: 'is', value: 'true')
      result = apply_filter(rule)

      expect(result).to include(billed_session)
      expect(result).not_to include(unbilled_session)
    end

    it "filters unbilled sessions (value 'false')" do
      rule = build_rule(field: 'billed', operator: 'is', value: 'false')
      result = apply_filter(rule)

      expect(result).to include(unbilled_session)
      expect(result).not_to include(billed_session)
    end
  end

  # -- billed: operator 'is_not' ---------------------------------------

  describe "field 'billed', operator 'is_not'" do
    it "filters sessions that are NOT billed (value 'true')" do
      rule = build_rule(field: 'billed', operator: 'is_not', value: 'true')
      result = apply_filter(rule)

      expect(result).to include(unbilled_session)
      expect(result).not_to include(billed_session)
    end

    it "filters sessions that are NOT unbilled (value 'false')" do
      rule = build_rule(field: 'billed', operator: 'is_not', value: 'false')
      result = apply_filter(rule)

      expect(result).to include(billed_session)
      expect(result).not_to include(unbilled_session)
    end
  end

  # -- Edge cases: various truthy/falsy values --------------------------

  describe 'truthy value coercion' do
    %w[true 1].each do |truthy_val|
      it "treats '#{truthy_val}' as truthy" do
        rule = build_rule(field: 'billed', operator: 'is', value: truthy_val)
        result = apply_filter(rule)

        expect(result).to include(billed_session)
        expect(result).not_to include(unbilled_session)
      end
    end

    %w[false 0].each do |falsy_val|
      it "treats '#{falsy_val}' as falsy" do
        rule = build_rule(field: 'billed', operator: 'is', value: falsy_val)
        result = apply_filter(rule)

        expect(result).to include(unbilled_session)
        expect(result).not_to include(billed_session)
      end
    end

    it 'treats an arbitrary string as falsy (bypassing model validation)' do
      rule = build_rule(field: 'billed', operator: 'is', value: 'false')
      rule.update_column(:value, 'random_string')
      rule.reload
      result = apply_filter(rule)

      expect(result).to include(unbilled_session)
      expect(result).not_to include(billed_session)
    end

    it 'treats nil value as falsy' do
      rule = build_rule(field: 'billed', operator: 'is', value: 'false')
      # Manually set to nil, since factory validation prevents this
      rule.update_column(:value, nil)
      rule.reload
      result = apply_filter(rule)

      expect(result).to include(unbilled_session)
      expect(result).not_to include(billed_session)
    end
  end

  # -- Edge case: wrong item_type ---------------------------------------

  describe 'type mismatch' do
    it 'returns query unchanged when item_type is not TimeSession' do
      rule = build_rule(field: 'billed', operator: 'is', value: 'true')
      query = TimeSession.all
      result = apply_filter(rule, query: query, item_type: 'Ticket')

      expect(result.to_sql).to eq(query.to_sql)
    end

    it 'returns query unchanged when query model does not match item_type' do
      rule = build_rule(field: 'billed', operator: 'is', value: 'true')
      # item_type says TimeSession, but the query is on Ticket
      ticket_query = Ticket.all
      result = apply_filter(rule, query: ticket_query, item_type: 'TimeSession')

      expect(result.to_sql).to eq(ticket_query.to_sql)
    end
  end

  # -- Edge case: unknown operator --------------------------------------

  describe 'unsupported operator' do
    it 'returns query unchanged and logs warning' do
      rule = build_rule(field: 'billed', operator: 'is', value: 'true')
      rule.update_column(:operator, 'contains')
      rule.reload

      expect(Rails.logger).to receive(:warn).with(/unsupported operator 'contains'/)

      query = TimeSession.all
      result = apply_filter(rule)

      expect(result.to_sql).to eq(query.to_sql)
    end
  end

  # -- Edge case: unknown field -----------------------------------------

  describe 'unhandled field' do
    it 'returns query unchanged and logs warning' do
      rule = build_rule(field: 'billed', operator: 'is', value: 'true')
      rule.update_column(:field, 'unknown_field')
      rule.reload

      expect(Rails.logger).to receive(:warn).with(/unhandled field 'unknown_field'/)

      query = TimeSession.all
      result = apply_filter(rule)

      expect(result.to_sql).to eq(query.to_sql)
    end
  end

  # -- Edge case: all sessions billed / none billed ---------------------

  describe 'boundary: all or none billed' do
    context 'when all sessions are billed' do
      before { unbilled_session.update!(billed_at: Time.current) }

      it "returns all with operator 'is' + value 'true'" do
        rule = build_rule(field: 'billed', operator: 'is', value: 'true')
        result = apply_filter(rule)

        expect(result.count).to eq(2)
      end

      it "returns none with operator 'is' + value 'false'" do
        rule = build_rule(field: 'billed', operator: 'is', value: 'false')
        result = apply_filter(rule)

        expect(result.count).to eq(0)
      end
    end

    context 'when no sessions are billed' do
      before { billed_session.update!(billed_at: nil) }

      it "returns none with operator 'is' + value 'true'" do
        rule = build_rule(field: 'billed', operator: 'is', value: 'true')
        result = apply_filter(rule)

        expect(result.count).to eq(0)
      end

      it "returns all with operator 'is' + value 'false'" do
        rule = build_rule(field: 'billed', operator: 'is', value: 'false')
        result = apply_filter(rule)

        expect(result.count).to eq(2)
      end
    end
  end

  # -- Edge case: empty table -------------------------------------------

  describe 'empty dataset' do
    before do
      TimeSession.delete_all
    end

    it 'returns empty relation without errors' do
      rule = build_rule(field: 'billed', operator: 'is', value: 'true')
      result = apply_filter(rule)

      expect(result).to be_empty
      expect(result).to be_a(ActiveRecord::Relation)
    end
  end
end
