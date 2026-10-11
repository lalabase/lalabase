# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Projects::PriorityLevelBackfillService do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def priority_without_levels(values)
    create(:ticket_attribute_definition, :select, project: project, name: 'priority',
                                                  options: { 'allowed_values' => values.map { |v| { 'value' => v, 'labels' => { 'de' => v, 'en' => v } } } })
  end

  it 'adds 1-based levels derived from current option order' do
    definition = priority_without_levels(%w[low normal high urgent])

    described_class.call

    expect(definition.reload.options['allowed_values'].map { |opt| opt['level'] }).to eq([1, 2, 3, 4])
  end

  it 'is idempotent (skips definitions that already carry levels)' do
    definition = priority_without_levels(%w[low high])
    described_class.call

    result = described_class.call

    expect(result.skipped).to be >= 1
    expect(definition.reload.options['allowed_values'].map { |opt| opt['level'] }).to eq([1, 2])
  end

  it 'revert strips the levels back out' do
    definition = priority_without_levels(%w[low normal])
    described_class.call

    described_class.revert

    expect(definition.reload.options['allowed_values'].map { |opt| opt.key?('level') }).to eq([false, false])
  end
end
