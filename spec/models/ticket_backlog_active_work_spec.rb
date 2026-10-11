# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TicketAttributeDefinition, '.backlog_status_values_for' do
  let(:organisation) { create(:organisation) }
  let!(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  before { ActsAsTenant.current_tenant = organisation }

  def create_status_def(proj, options_list, name: 'status', field_type: 'select')
    allowed_values = options_list.map do |value, functions|
      entry = { 'value' => value, 'labels' => { 'de' => value } }
      entry['system_functions'] = functions if functions
      entry
    end
    create(:ticket_attribute_definition,
           project: proj, name: name, field_type: field_type, system: true,
           options: { 'allowed_values' => allowed_values })
  end

  it 'returns downcased values tagged is_backlog' do
    create_status_def(project, [
                        ['Backlog', ['is_backlog']],
                        ['Neu', ['is_new']],
                        ['Erledigt', ['is_completed']]
                      ])

    expect(described_class.backlog_status_values_for([project.id])).to contain_exactly('backlog')
  end

  it 'returns empty when no option is tagged is_backlog' do
    create_status_def(project, [['Neu', ['is_new']], ['Erledigt', ['is_completed']]])

    expect(described_class.backlog_status_values_for([project.id])).to be_empty
  end

  it 'collects and deduplicates across multiple projects' do
    project_b = create(:project, organisation: organisation)
    create_status_def(project, [['Backlog', ['is_backlog']]])
    create_status_def(project_b, [['Backlog', ['is_backlog']]])

    expect(described_class.backlog_status_values_for([project.id, project_b.id])).to eq(['backlog'])
  end

  it 'ignores inactive definitions' do
    attr_def = create_status_def(project, [['Backlog', ['is_backlog']]])
    attr_def.update!(active: false)

    expect(described_class.backlog_status_values_for([project.id])).to be_empty
  end

  # Defense in depth (Codex): the cross-field Resolver aggregates over all select
  # attributes, so resolution MUST be scoped to the status attribute. A non-status
  # field carrying is_backlog (forced past validation) must not leak in.
  it 'only reads the status attribute, not other select fields' do
    create_status_def(project, [['Neu', ['is_new']]])
    rogue = build(:ticket_attribute_definition,
                  project: project, name: 'phase', field_type: 'select', system: false,
                  options: { 'allowed_values' => [{ 'value' => 'Later', 'system_functions' => ['is_backlog'] }] })
    rogue.save!(validate: false)

    expect(described_class.backlog_status_values_for([project.id])).to be_empty
  end
end

RSpec.describe Ticket, '.active_work' do
  let(:organisation) { create(:organisation) }
  let!(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end
  let(:user) { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:ticket_attribute_definition,
           project: project, name: 'status', field_type: 'select', system: true,
           options: { 'allowed_values' => [
             { 'value' => 'Backlog', 'labels' => { 'de' => 'Backlog' }, 'system_functions' => ['is_backlog'] },
             { 'value' => 'Neu', 'labels' => { 'de' => 'Neu' }, 'system_functions' => ['is_new'] },
             { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] }
           ] })
  end

  def ticket_with(status)
    create(:ticket, project: project, organisation: organisation, creator: user,
                    custom_attributes: status.nil? ? {} : { 'status' => status })
  end

  it 'excludes backlog tickets and keeps active ones' do
    active = ticket_with('Neu')
    done = ticket_with('Erledigt')
    ticket_with('Backlog')

    # closed/completed are intentionally NOT excluded by active_work (backlog only)
    expect(project.tickets.active_work).to contain_exactly(active, done)
  end

  it 'keeps nil-status (untriaged) tickets as active' do
    untriaged = ticket_with(nil)
    ticket_with('Backlog')

    expect(project.tickets.active_work).to contain_exactly(untriaged)
  end

  it 'returns all tickets when no backlog status is configured' do
    project.ticket_attribute_definitions.find_by(name: 'status')
           .update!(options: { 'allowed_values' => [
                      { 'value' => 'Neu', 'labels' => { 'de' => 'Neu' }, 'system_functions' => ['is_new'] },
                      { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] }
                    ] })
    a = ticket_with('Neu')
    b = ticket_with('Erledigt')

    expect(project.tickets.active_work).to contain_exactly(a, b)
  end

  it 'derives the project scope from the relation (no cross-project leak)' do
    project_b = create(:project, organisation: organisation)
    create(:ticket_attribute_definition,
           project: project_b, name: 'status', field_type: 'select', system: true,
           options: { 'allowed_values' => [
             { 'value' => 'Backlog', 'labels' => { 'de' => 'Backlog' }, 'system_functions' => ['is_backlog'] }
           ] })
    a = ticket_with('Neu')
    ticket_with('Backlog')
    b_backlog = create(:ticket, project: project_b, organisation: organisation, creator: user,
                                custom_attributes: { 'status' => 'Backlog' })

    expect(project.tickets.active_work).to contain_exactly(a)
    expect(project_b.tickets.active_work).to be_empty
    expect(Ticket.where(id: b_backlog.id).active_work).to be_empty
  end
end
