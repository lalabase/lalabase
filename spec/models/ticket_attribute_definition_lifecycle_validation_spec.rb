# frozen_string_literal: true

require 'rails_helper'

# Lifecycle System Function invariants (D2 + Codex scope-to-status):
#   - a status option may carry at most one of {is_completed, is_closed, is_backlog}
#   - status-category functions are only valid on the `status` attribute
RSpec.describe TicketAttributeDefinition, 'lifecycle system function validation' do
  let(:organisation) { create(:organisation) }
  let!(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  before { ActsAsTenant.current_tenant = organisation }

  def status_def(options_list, name: 'status', field_type: 'select')
    allowed_values = options_list.map do |value, functions|
      { 'value' => value, 'labels' => { 'de' => value }, 'system_functions' => functions }
    end
    build(:ticket_attribute_definition,
          project: project, name: name, field_type: field_type, system: true,
          options: { 'allowed_values' => allowed_values })
  end

  it 'rejects an option tagged both is_backlog and is_closed' do
    record = status_def([['Komisch', %w[is_backlog is_closed]]])

    expect(record).not_to be_valid
    expect(record.errors[:options].join).to include('Komisch')
  end

  it 'rejects is_backlog combined with is_completed' do
    expect(status_def([['X', %w[is_backlog is_completed]]])).not_to be_valid
  end

  # completed + closed are BOTH "done" — redundant, not contradictory — so they may
  # coexist on one option (e.g. an "abgenommen" status). Only backlog-vs-done is rejected.
  it 'allows is_completed combined with is_closed (both are "done")' do
    expect(status_def([['Abgenommen', %w[is_completed is_closed]]])).to be_valid
  end

  it 'allows a single lifecycle function per option' do
    record = status_def([
                          ['Backlog', ['is_backlog']],
                          ['Neu', ['is_new']],
                          ['Erledigt', ['is_completed']],
                          ['Geschlossen', ['is_closed']]
                        ])

    expect(record).to be_valid
  end

  it 'allows non-exclusive status functions to coexist (is_new + is_open)' do
    expect(status_def([['Eingang', %w[is_new is_open]]])).to be_valid
  end

  # Validation does NOT restrict status functions to the status field (that would
  # break the cross-field Resolver, which intentionally aggregates over all select
  # attributes). Contamination of active_work is prevented at the FILTER layer
  # instead — backlog_status_values_for reads only the status attribute.
  it 'allows status functions on a non-status field (filter scoping guards active_work)' do
    record = status_def([['Spaeter', ['is_backlog']]], name: 'phase')

    expect(record).to be_valid
  end

  it 'allows non-status functions on non-status fields (priority)' do
    record = status_def([['Hoch', ['high_priority']]], name: 'priority')

    expect(record).to be_valid
  end
end
