# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SmartFolders::Filters::TimeSessionFilter, type: :model do
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

  def apply_filter(rule, query: Ticket.all)
    described_class.new(rule).apply(query, 'Ticket')
  end

  # -- Testdaten ----------------------------------------------------------
  #
  # ticket_a: 2 unbilled sessions, durations 120 + 60 = total 180 min
  # ticket_b: 1 unbilled session,  duration 30 min
  # ticket_c: no sessions at all
  # ticket_d: 1 billed session,    duration 60 min
  # ticket_e: 2 sessions (45 billed + 30 unbilled), total 75 min
  #
  let!(:ticket_a) { create(:ticket, project: project, organisation: organisation) }
  let!(:ticket_b) { create(:ticket, project: project, organisation: organisation) }
  let!(:ticket_c) { create(:ticket, project: project, organisation: organisation) }
  let!(:ticket_d) { create(:ticket, project: project, organisation: organisation) }
  let!(:ticket_e) { create(:ticket, project: project, organisation: organisation) }

  before do
    create(:time_session, ticket: ticket_a, project: project, organisation: organisation, duration: 120)
    create(:time_session, ticket: ticket_a, project: project, organisation: organisation, duration: 60)

    create(:time_session, ticket: ticket_b, project: project, organisation: organisation, duration: 30)

    # ticket_c: intentionally no sessions

    create(:time_session, ticket: ticket_d, project: project, organisation: organisation,
                          duration: 60, billed_at: 1.day.ago)

    create(:time_session, ticket: ticket_e, project: project, organisation: organisation,
                          duration: 45, billed_at: 1.day.ago)
    create(:time_session, ticket: ticket_e, project: project, organisation: organisation,
                          duration: 30)
  end

  # ===================================================================
  # field: time_session_duration
  # ===================================================================

  describe "field 'time_session_duration'" do
    describe "operator 'equals'" do
      it 'finds tickets whose total duration matches exactly' do
        rule = build_rule(field: 'time_session_duration', operator: 'equals', value: '180')

        expect(apply_filter(rule)).to contain_exactly(ticket_a)
      end

      it 'sums durations across multiple sessions' do
        rule = build_rule(field: 'time_session_duration', operator: 'equals', value: '75')

        expect(apply_filter(rule)).to contain_exactly(ticket_e)
      end

      it 'does not include tickets without sessions (SUM is NULL, not 0)' do
        rule = build_rule(field: 'time_session_duration', operator: 'equals', value: '0')

        expect(apply_filter(rule)).not_to include(ticket_c)
      end
    end

    describe "operator 'not_equals'" do
      it 'finds tickets with different total duration' do
        rule = build_rule(field: 'time_session_duration', operator: 'not_equals', value: '180')
        result = apply_filter(rule)

        expect(result).to include(ticket_b, ticket_d, ticket_e)
        expect(result).not_to include(ticket_a)
      end

      it 'includes tickets without sessions (NULL IS NULL clause)' do
        rule = build_rule(field: 'time_session_duration', operator: 'not_equals', value: '180')

        expect(apply_filter(rule)).to include(ticket_c)
      end
    end

    describe "operator 'greater_than'" do
      it 'finds tickets with total duration above threshold' do
        rule = build_rule(field: 'time_session_duration', operator: 'greater_than', value: '60')

        expect(apply_filter(rule)).to contain_exactly(ticket_a, ticket_e)
      end

      it 'excludes tickets without sessions' do
        rule = build_rule(field: 'time_session_duration', operator: 'greater_than', value: '0')

        expect(apply_filter(rule)).not_to include(ticket_c)
      end
    end

    describe "operator 'less_than'" do
      it 'finds tickets with total duration below threshold' do
        rule = build_rule(field: 'time_session_duration', operator: 'less_than', value: '60')

        expect(apply_filter(rule)).to contain_exactly(ticket_b)
      end

      it 'excludes tickets without sessions' do
        rule = build_rule(field: 'time_session_duration', operator: 'less_than', value: '999')

        expect(apply_filter(rule)).not_to include(ticket_c)
      end
    end

    describe "operator 'between'" do
      it 'finds tickets with total duration in range (inclusive)' do
        rule = build_rule(field: 'time_session_duration', operator: 'between', value: '30,75')

        expect(apply_filter(rule)).to contain_exactly(ticket_b, ticket_d, ticket_e)
      end

      it 'handles reversed range values (auto-sorts min/max)' do
        rule = build_rule(field: 'time_session_duration', operator: 'between', value: '30,75')
        rule.update_column(:value, '75,30')
        rule.reload

        expect(apply_filter(rule)).to contain_exactly(ticket_b, ticket_d, ticket_e)
      end
    end

    describe 'edge cases' do
      it 'returns query.none for invalid number value' do
        rule = build_rule(field: 'time_session_duration', operator: 'equals', value: '30')
        rule.update_column(:value, 'not_a_number')
        rule.reload

        expect(apply_filter(rule)).to be_empty
      end

      it 'returns query unchanged for unsupported operator' do
        rule = build_rule(field: 'time_session_duration', operator: 'equals', value: '30')
        rule.update_column(:operator, 'contains')
        rule.reload

        expect(Rails.logger).to receive(:warn).with(/Unsupported operator/)
        expect(apply_filter(rule).to_sql).to eq(Ticket.all.to_sql)
      end

      it 'truncates decimal values to integer (duration is integer column)' do
        rule = build_rule(field: 'time_session_duration', operator: 'greater_than', value: '29.5')

        # 29.5 → 29 via .to_i, ticket_b has duration 30 > 29
        expect(apply_filter(rule)).to include(ticket_b)
      end
    end
  end

  # ===================================================================
  # field: time_session_count
  # ===================================================================

  describe "field 'time_session_count'" do
    describe "operator 'equals'" do
      it 'finds tickets with matching session count' do
        rule = build_rule(field: 'time_session_count', operator: 'equals', value: '2')

        expect(apply_filter(rule)).to contain_exactly(ticket_a, ticket_e)
      end

      it 'finds tickets with zero sessions (COUNT returns 0 on LEFT JOIN)' do
        rule = build_rule(field: 'time_session_count', operator: 'equals', value: '0')

        expect(apply_filter(rule)).to contain_exactly(ticket_c)
      end

      it 'finds tickets with exactly one session' do
        rule = build_rule(field: 'time_session_count', operator: 'equals', value: '1')

        expect(apply_filter(rule)).to contain_exactly(ticket_b, ticket_d)
      end
    end

    describe "operator 'not_equals'" do
      it 'finds tickets with different session count' do
        rule = build_rule(field: 'time_session_count', operator: 'not_equals', value: '2')
        result = apply_filter(rule)

        expect(result).to include(ticket_b, ticket_c, ticket_d)
        expect(result).not_to include(ticket_a, ticket_e)
      end
    end

    describe "operator 'greater_than'" do
      it 'finds tickets with more sessions than threshold' do
        rule = build_rule(field: 'time_session_count', operator: 'greater_than', value: '1')

        expect(apply_filter(rule)).to contain_exactly(ticket_a, ticket_e)
      end

      it 'excludes tickets with zero sessions' do
        rule = build_rule(field: 'time_session_count', operator: 'greater_than', value: '0')

        expect(apply_filter(rule)).not_to include(ticket_c)
      end
    end

    describe "operator 'less_than'" do
      it 'finds tickets with fewer sessions than threshold' do
        rule = build_rule(field: 'time_session_count', operator: 'less_than', value: '2')

        expect(apply_filter(rule)).to include(ticket_b, ticket_c, ticket_d)
      end
    end

    describe "operator 'between'" do
      it 'finds tickets with session count in range (inclusive)' do
        rule = build_rule(field: 'time_session_count', operator: 'between', value: '1,2')

        expect(apply_filter(rule)).to contain_exactly(ticket_a, ticket_b, ticket_d, ticket_e)
      end
    end

    describe 'edge cases' do
      it 'returns query.none for invalid number value' do
        rule = build_rule(field: 'time_session_count', operator: 'equals', value: '1')
        rule.update_column(:value, 'abc')
        rule.reload

        expect(apply_filter(rule)).to be_empty
      end
    end
  end

  # ===================================================================
  # field: time_session_billed
  # ===================================================================

  describe "field 'time_session_billed'" do
    describe "operator 'is', value 'true'" do
      it 'finds tickets with at least one billed session' do
        rule = build_rule(field: 'time_session_billed', operator: 'is', value: 'true')

        expect(apply_filter(rule)).to contain_exactly(ticket_d, ticket_e)
      end
    end

    describe "operator 'is', value 'false'" do
      it 'finds tickets where all sessions are unbilled' do
        rule = build_rule(field: 'time_session_billed', operator: 'is', value: 'false')
        result = apply_filter(rule)

        expect(result).to include(ticket_a, ticket_b)
        expect(result).not_to include(ticket_d, ticket_e)
      end

      it 'includes tickets without sessions' do
        rule = build_rule(field: 'time_session_billed', operator: 'is', value: 'false')

        expect(apply_filter(rule)).to include(ticket_c)
      end
    end

    describe "operator 'is_not', value 'true' (equivalent to is+false)" do
      it 'finds tickets where no session is billed' do
        rule = build_rule(field: 'time_session_billed', operator: 'is_not', value: 'true')
        result = apply_filter(rule)

        expect(result).to include(ticket_a, ticket_b, ticket_c)
        expect(result).not_to include(ticket_d, ticket_e)
      end
    end

    describe "operator 'is_not', value 'false' (equivalent to is+true)" do
      it 'finds tickets with at least one billed session' do
        rule = build_rule(field: 'time_session_billed', operator: 'is_not', value: 'false')

        expect(apply_filter(rule)).to contain_exactly(ticket_d, ticket_e)
      end
    end

    describe 'unsupported operator' do
      it 'returns query unchanged and logs warning' do
        rule = build_rule(field: 'time_session_billed', operator: 'is', value: 'true')
        rule.update_column(:operator, 'contains')
        rule.reload

        expect(Rails.logger).to receive(:warn).with(/Unsupported operator/)
        expect(apply_filter(rule).to_sql).to eq(Ticket.all.to_sql)
      end
    end
  end

  # ===================================================================
  # General edge cases
  # ===================================================================

  describe 'item_type guard' do
    it 'returns query unchanged for non-Ticket item_type' do
      rule = build_rule(field: 'time_session_duration', operator: 'equals', value: '60')
      query = Ticket.all
      result = described_class.new(rule).apply(query, 'TimeSession')

      expect(result.to_sql).to eq(query.to_sql)
    end
  end

  describe 'unsupported field' do
    it 'returns query unchanged and logs warning' do
      rule = build_rule(field: 'time_session_duration', operator: 'equals', value: '60')
      rule.update_column(:field, 'time_session_unknown')
      rule.reload

      expect(Rails.logger).to receive(:warn).with(/Unsupported field/)
      expect(apply_filter(rule).to_sql).to eq(Ticket.all.to_sql)
    end
  end

  describe 'soft-deleted time sessions' do
    it 'excludes soft-deleted sessions from duration aggregation' do
      ticket = create(:ticket, project: project, organisation: organisation)
      ts = create(:time_session, ticket: ticket, project: project, organisation: organisation, duration: 100)
      create(:time_session, ticket: ticket, project: project, organisation: organisation, duration: 50)

      ts.update_column(:deleted_at, Time.current)

      rule = build_rule(field: 'time_session_duration', operator: 'equals', value: '50')
      expect(apply_filter(rule)).to include(ticket)
    end

    it 'excludes soft-deleted sessions from count' do
      ticket = create(:ticket, project: project, organisation: organisation)
      ts = create(:time_session, ticket: ticket, project: project, organisation: organisation, duration: 100)
      create(:time_session, ticket: ticket, project: project, organisation: organisation, duration: 50)

      ts.update_column(:deleted_at, Time.current)

      rule = build_rule(field: 'time_session_count', operator: 'equals', value: '1')
      expect(apply_filter(rule)).to include(ticket)
    end
  end

  describe 'empty result set' do
    it 'returns empty relation when no tickets match' do
      rule = build_rule(field: 'time_session_duration', operator: 'equals', value: '999999')
      result = apply_filter(rule)

      expect(result).to be_empty
      expect(result).to be_a(ActiveRecord::Relation)
    end
  end

  describe 'join deduplication' do
    it 'does not add time_sessions join when already present' do
      rule = build_rule(field: 'time_session_duration', operator: 'equals', value: '180')
      pre_joined = Ticket.all.joins(
        'LEFT JOIN time_sessions ON time_sessions.ticket_id = tickets.id AND time_sessions.deleted_at IS NULL'
      )

      result = apply_filter(rule, query: pre_joined)

      expect(result).to contain_exactly(ticket_a)
    end
  end
end
