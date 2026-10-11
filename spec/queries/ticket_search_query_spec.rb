# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TicketSearchQuery, type: :model do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user, organisation: organisation) }

  before do
    create(:ticket_attribute_definition, :select,
           project: project,
           name: 'priority',
           options: { 'allowed_values' => [
             { 'value' => 'low', 'labels' => { 'de' => 'Niedrig', 'en' => 'Low' } },
             { 'value' => 'high', 'labels' => { 'de' => 'Hoch', 'en' => 'High' } }
           ] })
  end

  def ticket_with(title, priority)
    create(:ticket, project: project, organisation: organisation, creator: user,
                    title: title, custom_attributes: { 'priority' => priority })
  end

  # Guards the SortableQuery path: status/priority previously mapped onto the dropped
  # ticket_priorities/ticket_statuses tables (ORDER BY ticket_priorities.name → SQL
  # error, swallowed into an unfiltered fallback). They now sort by configured order.
  describe '#call sorting by a configured custom attribute' do
    it 'orders by the configured priority option order ascending' do
      high = ticket_with('HighOne', 'high')
      low = ticket_with('LowOne', 'low')

      result = described_class.new(project, { sort: { column: 'priority', direction: 'asc' } }).call

      expect(result.to_a).to eq([low, high])
    end

    it 'reverses the configured order on desc' do
      high = ticket_with('HighOne', 'high')
      low = ticket_with('LowOne', 'low')

      result = described_class.new(project, { sort: { column: 'priority', direction: 'desc' } }).call

      expect(result.to_a).to eq([high, low])
    end

    it 'does not reference the dropped ticket_priorities table (no SQL error)' do
      ticket_with('AnyTicket', 'high')

      expect do
        described_class.new(project, { sort: { column: 'priority', direction: 'asc' } }).call.to_a
      end.not_to raise_error
    end
  end
  %w[Ticket All].each do |target|
    it "filters actual ticket results through a #{target} saved view" do
      selected = ticket_with('Match', 'high')
      ticket_with('Not selected', 'low')
      saved = create(:smart_folder, organisation: organisation, project: project, user: user, target_object_type: target)
      group = saved.smart_folder_rule_groups.create!(position: 1)
      group.smart_folder_rules.create!(field: 'title', operator: 'equals', value: 'Match', position: 1)
      result = described_class.new(project, { smart_folder_id: saved.id }, current_user: user, policy_scope: SmartFolder.all).call
      expect(result.pluck(:id)).to eq([selected.id])
    end
  end

  # Regression guard (26.09.2026): the content and full modes passed an unused named
  # bind (`search: search_term`) next to a condition that already carried the quoted
  # search term. Rails substitutes `:search` anywhere in the string, including inside
  # that quoted literal, so a term containing ":search" closed the literal and the
  # rest of the term ran as SQL (read access across all tenants for any member).
  describe 'full-text search with a term containing a named-bind token' do
    let(:payload) { '||version()||/*:search*/' }

    # Checked on the SQL text, not by running it: Postgres folds the constant
    # to_tsquery calls at plan time, so the tsquery syntax error this term causes
    # in the SELECT list surfaces before any injected expression would run.
    # The SELECT list also carries the intact literal, hence every call is checked.
    %w[title_only content full].each do |mode|
      it "passes the term to every to_tsquery call as one quoted literal in #{mode} mode" do
        sql = described_class.new(project, { search: payload, search_mode: mode }).call.to_sql
        calls = sql.scan("to_tsquery('german', ")
        intact = sql.scan("to_tsquery('german', #{Ticket.connection.quote("#{payload}:*")})")

        expect(calls).not_to be_empty
        expect(intact.size).to eq(calls.size)
      end
    end

    it 'still finds tickets by a word in the title' do
      match = ticket_with('Angebot Nordsee', 'low')
      ticket_with('Rechnung Ostsee', 'low')

      result = described_class.new(project, { search: 'Angebot', search_mode: 'content' }).call

      expect(result.map(&:id)).to eq([match.id])
    end
  end

  it 'ignores a private view of another user even when the folder lookup is unscoped' do
    ticket_with('Match', 'high')
    hidden = create(:smart_folder, organisation: organisation, project: project, user: create(:user),
                                   target_object_type: 'Ticket', is_public: false)
    hidden.smart_folder_rule_groups.create!(position: 1)
          .smart_folder_rules.create!(field: 'title', operator: 'equals', value: 'Match', position: 1)
    result = described_class.new(project, { smart_folder_id: hidden.id }, current_user: user, policy_scope: SmartFolder.all).call
    expect(result.pluck(:id)).to be_empty
  end
end
