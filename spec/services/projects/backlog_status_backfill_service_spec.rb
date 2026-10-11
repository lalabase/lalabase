# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Projects::BacklogStatusBackfillService do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def status_def(project, options_list)
    allowed = options_list.map do |value, functions|
      opt = { 'value' => value, 'labels' => { 'de' => value } }
      opt['system_functions'] = functions if functions
      opt
    end
    create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                         system: true, options: { 'allowed_values' => allowed })
  end

  it 'appends a backlog option (is_backlog) to a status attribute that lacks one' do
    project = create(:project, organisation: organisation)
    definition = status_def(project, [['Neu', ['is_new']], ['Erledigt', ['is_completed']]])

    result = described_class.call

    definition.reload
    expect(definition.allowed_values.map { |o| o['value'] }).to eq(%w[Neu Erledigt backlog])
    expect(definition.allowed_values.last['system_functions']).to eq(['is_backlog'])
    expect(result.added).to eq(1)
    expect(result.skipped).to eq(0)
  end

  it 'is idempotent — a second run adds nothing' do
    project = create(:project, organisation: organisation)
    status_def(project, [['Neu', ['is_new']]])

    described_class.call
    second = described_class.call

    definition = project.ticket_attribute_definitions.find_by(name: 'status')
    expect(definition.allowed_values.count { |o| o['value'] == 'backlog' }).to eq(1)
    expect(second.added).to eq(0)
    expect(second.skipped).to eq(1)
  end

  it 'leaves a project that already has an is_backlog-tagged option untouched' do
    project = create(:project, organisation: organisation)
    status_def(project, [['Parkplatz', ['is_backlog']]])

    result = described_class.call

    definition = project.ticket_attribute_definitions.find_by(name: 'status')
    expect(definition.allowed_values.map { |o| o['value'] }).to eq(['Parkplatz'])
    expect(result.added).to eq(0)
    expect(result.skipped).to eq(1)
  end

  it 'does not duplicate when a custom value "backlog" already exists' do
    project = create(:project, organisation: organisation)
    status_def(project, [['backlog', nil]])

    result = described_class.call

    definition = project.ticket_attribute_definitions.find_by(name: 'status')
    expect(definition.allowed_values.count { |o| o['value'].to_s.casecmp?('backlog') }).to eq(1)
    expect(result.added).to eq(0)
  end

  it 'backfills multiple projects and reports the count' do
    p1 = create(:project, organisation: organisation)
    p2 = create(:project, organisation: organisation)
    status_def(p1, [['Neu', ['is_new']]])
    status_def(p2, [['Neu', ['is_new']]])

    # Per-row with_lock means one query per definition by design (a rare maintenance
    # task, not a request path) — Prosopite would otherwise flag it as N+1.
    Prosopite.pause
    result = described_class.call
    Prosopite.resume

    expect(result.added).to eq(2)
  end

  # The service is deliberately tenant-AGNOSTIC (TicketAttributeDefinition has no
  # acts_as_tenant) so the rake task — which runs with no tenant — reaches every org.
  # Guards that architectural claim: two projects in two different orgs both get backfilled.
  it 'crosses organisation boundaries when run without a tenant' do
    org2 = create(:organisation)
    p1 = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    p2 = ActsAsTenant.with_tenant(org2) { create(:project, organisation: org2) }
    ActsAsTenant.with_tenant(organisation) { status_def(p1, [['Neu', ['is_new']]]) }
    ActsAsTenant.with_tenant(org2) { status_def(p2, [['Neu', ['is_new']]]) }

    # Pause covers the per-row backfill AND the per-project re-reads below (both are
    # intentional one-query-per-record loops, not request-path N+1).
    Prosopite.pause
    result = ActsAsTenant.without_tenant { described_class.call }
    values_by_project = [p1, p2].map do |project|
      project.ticket_attribute_definitions.find_by(name: 'status').allowed_values.map { |o| o['value'] }
    end
    Prosopite.resume

    expect(result.added).to eq(2)
    values_by_project.each { |values| expect(values).to include('backlog') }
  end

  it 'handles a status definition whose options are blank (nil)' do
    project = create(:project, organisation: organisation)
    definition = build(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                                     labels: { 'de' => 'Status', 'en' => 'Status' }, options: nil)
    definition.save!(validate: false)

    described_class.call

    expect(definition.reload.allowed_values.map { |o| o['value'] }).to eq(['backlog'])
  end

  # Deploy-safety: grandfathered data that violates a current validation must NOT abort
  # the run (it crashed the production deploy once). The bad definition is counted as
  # failed and logged; healthy projects are still backfilled.
  it 'skips a definition that fails validation and still backfills the rest' do
    good = create(:project, organisation: organisation)
    bad = create(:project, organisation: organisation)
    status_def(good, [['Neu', ['is_new']]])
    bad_def = build(:ticket_attribute_definition, project: bad, name: 'status', field_type: 'select',
                                                  labels: { 'de' => 'Status' },
                                                  options: { 'allowed_values' => [{ 'value' => 'Komisch', 'system_functions' => ['is_bogus'] }] })
    bad_def.save!(validate: false)

    Prosopite.pause
    result = described_class.call
    Prosopite.resume

    expect(result.added).to eq(1)
    expect(result.failed).to eq(1)
    expect(good.ticket_attribute_definitions.find_by(name: 'status').allowed_values.map { |o| o['value'] }).to include('backlog')
    expect(bad_def.reload.allowed_values.map { |o| o['value'] }).not_to include('backlog')
  end
end
