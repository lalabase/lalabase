# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TicketColorMap, 'is_backlog colors' do
  let(:key) { SystemFunctions::Registry::IS_BACKLOG }

  it 'maps is_backlog to the neutral cream dot' do
    expect(described_class.dot_color_for_function(key)).to eq('bg-cream-400')
  end

  it 'maps is_backlog to the neutral cream badge' do
    expect(described_class.badge_color_for_function(key)).to eq('bg-cream-200 text-cream-700')
  end

  it 'keeps backlog visually distinct from closed' do
    closed = SystemFunctions::Registry::IS_CLOSED
    expect(described_class.dot_color_for_function(key))
      .not_to eq(described_class.dot_color_for_function(closed))
    expect(described_class.badge_color_for_function(key))
      .not_to eq(described_class.badge_color_for_function(closed))
  end
end
