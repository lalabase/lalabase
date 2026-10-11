# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TicketAttributeDefinition, '.closed_status_values_for' do
  let(:organisation) { create(:organisation) }
  let!(:project) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project, organisation: organisation)
    end
  end

  before { ActsAsTenant.current_tenant = organisation }

  def create_status_def(proj, options_list)
    allowed_values = options_list.map do |value, functions|
      entry = { 'value' => value, 'labels' => { 'de' => value } }
      entry['system_functions'] = functions if functions
      entry
    end

    create(:ticket_attribute_definition,
           project: proj,
           name: 'status',
           field_type: 'select',
           system: true,
           options: { 'allowed_values' => allowed_values })
  end

  it 'returns values with is_completed and is_closed system functions' do
    create_status_def(project, [
                        ['Offen', ['is_new']],
                        ['In Bearbeitung', ['is_in_progress']],
                        ['Erledigt', ['is_completed']],
                        ['Geschlossen', ['is_closed']]
                      ])

    result = described_class.closed_status_values_for([project.id])

    expect(result).to contain_exactly('erledigt', 'geschlossen')
  end

  it 'returns custom status names mapped to closed functions' do
    create_status_def(project, [
                        ['Neu', ['is_new']],
                        ['Abgelehnt', ['is_closed']],
                        ['Fertiggestellt', ['is_completed']]
                      ])

    result = described_class.closed_status_values_for([project.id])

    expect(result).to contain_exactly('abgelehnt', 'fertiggestellt')
  end

  it 'returns empty array when no system functions configured' do
    create_status_def(project, [
                        ['Offen', nil],
                        ['Geschlossen', nil]
                      ])

    result = described_class.closed_status_values_for([project.id])

    expect(result).to be_empty
  end

  it 'ignores inactive attribute definitions' do
    attr_def = create_status_def(project, [
                                   ['Offen', ['is_new']],
                                   ['Erledigt', ['is_completed']]
                                 ])
    attr_def.update!(active: false)

    result = described_class.closed_status_values_for([project.id])

    expect(result).to be_empty
  end

  it 'collects closed values across multiple projects' do
    project_b = create(:project, organisation: organisation)

    create_status_def(project, [
                        ['Open', ['is_new']],
                        ['Done', ['is_completed']]
                      ])
    create_status_def(project_b, [
                        ['Neu', ['is_new']],
                        ['Abgeschlossen', ['is_closed']]
                      ])

    result = described_class.closed_status_values_for([project.id, project_b.id])

    expect(result).to contain_exactly('done', 'abgeschlossen')
  end

  it 'deduplicates values across projects' do
    project_b = create(:project, organisation: organisation)

    create_status_def(project, [['Done', ['is_completed']]])
    create_status_def(project_b, [['Done', ['is_completed']]])

    result = described_class.closed_status_values_for([project.id, project_b.id])

    expect(result).to eq(['done'])
  end

  # Defense in depth: resolution is scoped to the `status` attribute. A non-status select
  # field carrying is_closed (forced past validation) must NOT leak into the closed set,
  # or active_work / open-ticket counts would silently exclude unrelated tickets. Guards
  # the `name: 'status'` filter in status_values_with_functions against accidental removal.
  it 'only reads the status attribute, not other select fields' do
    create_status_def(project, [['Erledigt', ['is_completed']]])
    rogue = build(:ticket_attribute_definition,
                  project: project, name: 'phase', field_type: 'select', system: false,
                  options: { 'allowed_values' => [{ 'value' => 'Abgehakt', 'system_functions' => ['is_closed'] }] })
    rogue.save!(validate: false)

    expect(described_class.closed_status_values_for([project.id])).to contain_exactly('erledigt')
  end
end

RSpec.describe Ticket, '.excluding_status_values' do
  let(:organisation) { create(:organisation) }
  let!(:project) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project, organisation: organisation)
    end
  end
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }

  it 'excludes tickets with closed status values' do
    open = create(:ticket, project: project, organisation: organisation, creator: user,
                           custom_attributes: { 'status' => 'Offen' })
    create(:ticket, project: project, organisation: organisation, creator: user,
                    custom_attributes: { 'status' => 'Erledigt' })

    result = Ticket.excluding_status_values(['erledigt'])

    expect(result).to contain_exactly(open)
  end

  it 'returns all tickets when closed_values is empty' do
    t1 = create(:ticket, project: project, organisation: organisation, creator: user,
                         custom_attributes: { 'status' => 'Offen' })
    t2 = create(:ticket, project: project, organisation: organisation, creator: user,
                         custom_attributes: { 'status' => 'Erledigt' })

    result = Ticket.excluding_status_values([])

    expect(result).to contain_exactly(t1, t2)
  end

  # Regression guard for the NULL-handling in the scope's SQL. A naive `where.not(IN)`
  # would drop NULL-status rows (NULL IN (...) is NULL); an untriaged ticket must survive
  # the exclusion. Tested directly on the scope so a simplification back to where.not is
  # caught here, not only transitively via active_work.
  it 'keeps a ticket with no status (untriaged) when excluding values' do
    untriaged = create(:ticket, project: project, organisation: organisation, creator: user,
                                custom_attributes: {})
    create(:ticket, project: project, organisation: organisation, creator: user,
                    custom_attributes: { 'status' => 'Erledigt' })

    result = Ticket.excluding_status_values(['erledigt'])

    expect(result).to contain_exactly(untriaged)
  end
end
