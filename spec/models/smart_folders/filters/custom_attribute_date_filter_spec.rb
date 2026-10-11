# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SmartFolders::Filters::CustomAttributeDateFilter, type: :model do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                         options: { 'allowed_values' => [
                                           { 'value' => 'open', 'labels' => { 'de' => 'Offen', 'en' => 'Open' } },
                                           { 'value' => 'closed', 'labels' => { 'de' => 'Zu', 'en' => 'Closed' },
                                             'system_functions' => [SystemFunctions::Registry::IS_CLOSED] }
                                         ] })
    create(:ticket_attribute_definition, project: project, name: 'due_date', field_type: 'date',
                                         labels: { 'de' => 'Fälligkeit', 'en' => 'Due date' })
  end

  after { ActsAsTenant.current_tenant = nil }

  def result_ids(operator, value = nil)
    rule = build_stubbed(:smart_folder_rule, field: 'custom_due_date', operator: operator, value: value)
    described_class.new(rule).apply(Ticket.where(project: project), 'Ticket').pluck(:id)
  end

  def ticket_with(due:, status: 'open')
    create(:ticket, project: project, custom_attributes: { 'due_date' => due, 'status' => status })
  end

  let!(:overdue_open)   { ticket_with(due: 3.days.ago.to_date.iso8601) }
  let!(:overdue_closed) { ticket_with(due: 3.days.ago.to_date.iso8601, status: 'closed') }
  let!(:due_today)      { ticket_with(due: Date.current.iso8601) }
  let!(:due_in_5)       { ticket_with(due: (Date.current + 5).iso8601) }
  let!(:due_in_20)      { ticket_with(due: (Date.current + 20).iso8601) }
  let!(:no_due)         { ticket_with(due: '') }

  describe 'absolute operators (fixes the previously broken before/after/between)' do
    it '`before` matches due dates strictly before the value, excluding blanks' do
      expect(result_ids('before', Date.current.iso8601)).to contain_exactly(overdue_open.id, overdue_closed.id)
    end

    it '`after` matches due dates strictly after the value' do
      expect(result_ids('after', Date.current.iso8601)).to contain_exactly(due_in_5.id, due_in_20.id)
    end

    it '`between` matches due dates within the inclusive range (ISO text, not numeric)' do
      value = "#{Date.current.iso8601},#{(Date.current + 7).iso8601}"
      expect(result_ids('between', value)).to contain_exactly(due_today.id, due_in_5.id)
    end

    it '`between` is INCLUSIVE on the upper bound (due exactly on `high` is in, high+1 is out)' do
      on_high   = ticket_with(due: (Date.current + 7).iso8601)
      past_high = ticket_with(due: (Date.current + 8).iso8601)
      value = "#{Date.current.iso8601},#{(Date.current + 7).iso8601}"

      ids = result_ids('between', value)
      expect(ids).to include(on_high.id)
      expect(ids).not_to include(past_high.id)
    end

    it '`between` sorts its bounds, so "high,low" matches the same range as "low,high"' do
      # Kills a mutation that drops the `.sort`: "+7,today" would become BETWEEN +7 AND today → empty.
      reversed = "#{(Date.current + 7).iso8601},#{Date.current.iso8601}"
      expect(result_ids('between', reversed)).to contain_exactly(due_today.id, due_in_5.id)
    end

    it '`between` with no parseable bounds leaves the query unchanged (no filter, no empty result)' do
      # Kills a mutation that drops the `return query if bounds.empty?` guard: BETWEEN NULL AND NULL
      # would otherwise match nothing instead of being a no-op.
      all_ids = Ticket.where(project: project).pluck(:id)
      expect(result_ids('between', 'garbage,nonsense')).to match_array(all_ids)
    end

    it '`equals` matches an exact date' do
      expect(result_ids('equals', Date.current.iso8601)).to contain_exactly(due_today.id)
    end

    it '`not_equals` returns everything except the exact match — INCLUDING the blank row (IS DISTINCT FROM)' do
      # not_equals is the one operator that deliberately keeps blank/NULL rows (a missing due date is
      # "not equal to" any date). Pins the IS DISTINCT FROM semantics so a refactor to plain != (which
      # would drop the blank row) is caught.
      expect(result_ids('not_equals', Date.current.iso8601))
        .to contain_exactly(overdue_open.id, overdue_closed.id, due_in_5.id, due_in_20.id, no_due.id)
    end

    it '`before` / `after` are STRICT — a ticket due exactly on the value is excluded by both' do
      on_boundary = ticket_with(due: (Date.current + 10).iso8601)
      boundary = (Date.current + 10).iso8601

      expect(result_ids('before', boundary)).not_to include(on_boundary.id)
      expect(result_ids('after', boundary)).not_to include(on_boundary.id)
    end

    it 'parses a German-format value into ISO for comparison' do
      expect(result_ids('equals', Date.current.strftime('%d.%m.%Y'))).to contain_exactly(due_today.id)
    end
  end

  describe 'relative deadline operators (valueless, saveable)' do
    it '`overdue` matches past-due AND not-closed tickets only (closed excluded)' do
      expect(result_ids('overdue')).to contain_exactly(overdue_open.id)
    end

    it '`due_today` matches tickets due today' do
      expect(result_ids('due_today')).to contain_exactly(due_today.id)
    end

    it '`due_next_7_days` matches due dates from today through +7 days' do
      expect(result_ids('due_next_7_days')).to contain_exactly(due_today.id, due_in_5.id)
    end

    it '`due_this_week` includes today and excludes far-future' do
      ids = result_ids('due_this_week')
      expect(ids).to include(due_today.id)
      expect(ids).not_to include(due_in_20.id)
    end
  end

  describe 'presence operators' do
    it '`is_empty` matches tickets without a due date' do
      expect(result_ids('is_empty')).to contain_exactly(no_due.id)
    end

    it '`is_not_empty` matches tickets with a due date' do
      expect(result_ids('is_not_empty'))
        .to contain_exactly(overdue_open.id, overdue_closed.id, due_today.id, due_in_5.id, due_in_20.id)
    end

    # The aliases share the case arm with is_empty / is_not_empty; each dies if its alias is dropped
    # (it would fall to the unknown-operator else branch and return ALL rows). Asserted directly (one
    # query each) rather than against is_empty to avoid tripping the N+1 detector on repeated queries.
    it '`is_blank` aliases is_empty (matches the blank-due row)' do
      expect(result_ids('is_blank')).to contain_exactly(no_due.id)
    end

    it '`is_not_blank` aliases is_not_empty (matches rows with a due date)' do
      expect(result_ids('is_not_blank'))
        .to contain_exactly(overdue_open.id, overdue_closed.id, due_today.id, due_in_5.id, due_in_20.id)
    end
  end

  describe 'unknown operator' do
    it 'leaves the query unchanged (safe no-op, never crashes or empties the list)' do
      all_ids = Ticket.where(project: project).pluck(:id)
      expect(result_ids('frobnicate')).to match_array(all_ids)
    end
  end
end
