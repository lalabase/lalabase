# frozen_string_literal: true

require 'rails_helper'

# "Done" per project (doc/ticket_relations_plan.md, revision 4, §5.2). The pooled
# closed_status_values_for throws the values of all projects into one list; that is wrong as
# soon as two projects give the same status name different meanings, which is exactly what a
# relation across projects meets. The per-project variant answers for each project on its own.
RSpec.describe TicketAttributeDefinition, '.closed_status_values_by_project' do
  let(:organisation) { create(:organisation) }
  let(:project_x) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:project_y) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def create_status_def(project, options_list, name: 'status')
    allowed_values = options_list.map do |value, functions|
      entry = { 'value' => value, 'labels' => { 'de' => value } }
      entry['system_functions'] = functions if functions
      entry
    end
    create(:ticket_attribute_definition, project: project, name: name, field_type: 'select', system: true,
                                         options: { 'allowed_values' => allowed_values })
  end

  it 'keeps the same status name apart when it means done in one project and open in the other' do
    create_status_def(project_x, [['Open', ['is_new']], ['Closed', ['is_closed']]])
    create_status_def(project_y, [['Open', ['is_new']], ['Closed', ['is_in_progress']]])

    result = described_class.closed_status_values_by_project([project_x.id, project_y.id])

    expect(result).to eq(project_x.id => ['closed'], project_y.id => [])
  end

  it 'reads both closing functions, downcased' do
    create_status_def(project_x, [['Erledigt', ['is_completed']], ['Abgelehnt', ['is_closed']], ['Neu', nil]])

    expect(described_class.closed_status_values_by_project([project_x.id]))
      .to eq(project_x.id => %w[erledigt abgelehnt])
  end

  it 'gives a project without a status definition no key' do
    create_status_def(project_x, [['Done', ['is_completed']]])

    result = described_class.closed_status_values_by_project([project_x.id, project_y.id])

    expect(result.keys).to eq([project_x.id])
  end

  it 'ignores an inactive definition and a select field other than status' do
    create_status_def(project_x, [['Done', ['is_completed']]]).update!(active: false)
    other = create_status_def(project_y, [['Done', nil]])
    other.update_column(:options, { 'allowed_values' => [{ 'value' => 'Done', 'system_functions' => ['is_closed'] }] })
    other.update_column(:name, 'phase')

    expect(described_class.closed_status_values_by_project([project_x.id, project_y.id])).to eq({})
  end

  it 'takes a relation of project ids as a subquery, in one query' do
    create_status_def(project_x, [['Done', ['is_completed']]])
    project_ids = Project.where(id: project_x.id).select(:id)

    queries = []
    callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == 'SCHEMA' }
    result = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      described_class.closed_status_values_by_project(project_ids)
    end

    expect(result).to eq(project_x.id => ['done'])
    expect(queries.size).to eq(1)
  end

  it 'leaves the pooled variant as it was: the union over all projects' do
    create_status_def(project_x, [['Done', ['is_completed']], ['Closed', ['is_closed']]])
    create_status_def(project_y, [['Done', ['is_completed']], ['Fertig', ['is_completed']]])

    expect(described_class.closed_status_values_for([project_x.id, project_y.id]))
      .to contain_exactly('done', 'closed', 'fertig')
  end
end
