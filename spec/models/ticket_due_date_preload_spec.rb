# frozen_string_literal: true

require 'rails_helper'

# Guards the N+1 boundary for the due-date + priority-bars per-row rendering. The ticket
# list/board preloads `project: :ticket_attribute_definitions` (TicketsController#
# optimized_ticket_includes); the per-row helpers (overdue?, priority level_for) must resolve
# through the ticket's MEMOIZED attribute_definitions, issuing NO query per row. prosopite
# (spec/support/prosopite.rb, scanning every example) fails this spec if a per-row query leaks.
RSpec.describe 'Ticket list due-date/priority preload', type: :model do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    # Setup creates tickets one-by-one; each save validates custom_attributes (a per-record
    # query that is NOT part of the list-render path under test). Pause N+1 detection for
    # setup and measure only the list path in the example below.
    Prosopite.pause
    create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                         options: { 'allowed_values' => [
                                           { 'value' => 'open', 'labels' => { 'de' => 'Offen', 'en' => 'Open' } },
                                           { 'value' => 'closed', 'labels' => { 'de' => 'Zu', 'en' => 'Closed' },
                                             'system_functions' => [SystemFunctions::Registry::IS_CLOSED] }
                                         ] })
    create(:ticket_attribute_definition, project: project, name: 'priority', field_type: 'select',
                                         options: { 'allowed_values' => [
                                           { 'value' => 'low', 'labels' => { 'de' => 'Niedrig', 'en' => 'Low' }, 'level' => 1 },
                                           { 'value' => 'high', 'labels' => { 'de' => 'Hoch', 'en' => 'High' }, 'level' => 2 }
                                         ] })
    create(:ticket_attribute_definition, project: project, name: 'due_date', field_type: 'date',
                                         labels: { 'de' => 'Fälligkeit', 'en' => 'Due date' })

    3.times do |i|
      create(:ticket, project: project, organisation: organisation,
                      custom_attributes: { 'due_date' => (2 - i).days.ago.to_date.iso8601, 'priority' => 'high', 'status' => 'open' })
    end
  end

  after { ActsAsTenant.current_tenant = nil }

  it 'resolves overdue? and priority level across many tickets without per-row queries' do
    Prosopite.resume
    tickets = Ticket.where(project: project).includes(project: :ticket_attribute_definitions).to_a

    tickets.each do |ticket|
      ticket.overdue?
      priority_definition = ticket.attribute_definitions.find { |definition| definition.name == 'priority' }
      priority_definition&.level_for(ticket.get_custom_attribute('priority'))
    end

    expect(tickets.size).to eq(3)
  end
end
