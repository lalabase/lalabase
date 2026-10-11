# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Projects::DueDateBackfillService do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  it 'provisions a deadline-marked due_date field into projects that lack it' do
    p1 = create(:project, organisation: organisation)
    p2 = create(:project, organisation: organisation)

    result = described_class.call

    expect(p1.ticket_attribute_definitions.find_by(name: 'due_date')&.field_type).to eq('date')
    expect(p2.ticket_attribute_definitions.find_by(name: 'due_date')&.deadline?).to be(true)
    expect(result.created).to eq(2)
  end

  it 'is idempotent (a second run creates nothing more)' do
    create(:project, organisation: organisation)
    described_class.call

    expect { described_class.call }.not_to(change { TicketAttributeDefinition.where(name: 'due_date').count })
  end

  it 'skips (does not overwrite) a conflicting non-date due_date' do
    project = create(:project, organisation: organisation)
    project.ticket_attribute_definitions.create!(name: 'due_date', field_type: 'text',
                                                 labels: { 'de' => 'x', 'en' => 'x' }, width: 'half', active: true)

    result = described_class.call

    expect(result.conflicts).to eq(1)
    expect(project.ticket_attribute_definitions.find_by(name: 'due_date').field_type).to eq('text')
  end

  it 'revert removes the auto-provisioned due_date fields' do
    create(:project, organisation: organisation)
    described_class.call

    expect { described_class.revert }
      .to change { TicketAttributeDefinition.where(name: 'due_date', field_type: 'date').count }.to(0)
  end
end
