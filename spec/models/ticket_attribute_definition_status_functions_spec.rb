# frozen_string_literal: true

require 'rails_helper'

# What each status of a project means: the status System Functions of its option, per
# project and per downcased value. A client outside the app (the terminal client) reads the
# meaning instead of guessing it from a name, because a name means something else in every
# project ("fertig" here, "resolved" there).
RSpec.describe TicketAttributeDefinition, '.status_functions_by_project' do
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

  it 'answers per project and per downcased value, an option without functions with none' do
    create_status_def(project_x, [['Neu', ['is_new']], ['Fertig', ['is_completed']], ['Wartet', nil]])
    create_status_def(project_y, [['Fertig', ['is_in_progress']]])

    result = described_class.status_functions_by_project([project_x.id, project_y.id])

    expect(result).to eq(
      project_x.id => { 'neu' => ['is_new'], 'fertig' => ['is_completed'], 'wartet' => [] },
      project_y.id => { 'fertig' => ['is_in_progress'] }
    )
  end

  it 'keeps only status functions, in the order of the registry' do
    create_status_def(project_x, [['Abgenommen', %w[is_closed high_priority is_completed]]])

    expect(described_class.status_functions_by_project([project_x.id]))
      .to eq(project_x.id => { 'abgenommen' => %w[is_completed is_closed] })
  end

  it 'joins the functions of two options whose values differ only in case' do
    create_status_def(project_x, [['Done', ['is_completed']], ['done', ['is_closed']]])

    expect(described_class.status_functions_by_project([project_x.id]))
      .to eq(project_x.id => { 'done' => %w[is_completed is_closed] })
  end

  it 'gives a project without an active status select no key' do
    create_status_def(project_x, [['Done', ['is_completed']]]).update!(active: false)
    create_status_def(project_y, [['Done', ['is_completed']]], name: 'phase')

    expect(described_class.status_functions_by_project([project_x.id, project_y.id])).to eq({})
  end

  it 'reads in one query' do
    create_status_def(project_x, [['Done', ['is_completed']]])
    create_status_def(project_y, [['Done', ['is_closed']]])

    queries = []
    callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      described_class.status_functions_by_project([project_x.id, project_y.id])
    end

    expect(queries.size).to eq(1)
  end
end
