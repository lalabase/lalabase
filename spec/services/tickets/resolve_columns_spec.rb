# frozen_string_literal: true

require 'rails_helper'

# What: Tickets::ResolveColumns, the one answer to "which columns, in which order".
# Type: unit spec over doubles; no database, the rule is pure.
# Why: two sources compete (the folder, the base view) and a key the reader
#   may not see must never reach the table. The
#   ranks are what the stylesheet and the fit rule key on, so an off-by-one
#   here shows the wrong column.
RSpec.describe Tickets::ResolveColumns do
  let(:available) do
    [
      { key: 'number', label: 'Nr.', type: 'number', required: true },
      { key: 'title', label: 'Titel', type: 'text', required: true },
      { key: 'assignees', label: 'Zugewiesen', type: 'users' },
      { key: 'tags', label: 'Tags', type: 'tags' },
      { key: 'created_at', label: 'Erstellt', type: 'datetime' },
      { key: 'custom_status', label: 'Status', type: 'select', custom: true },
      { key: 'custom_color', label: 'Farbe', type: 'color', custom: true }
    ]
  end
  let(:base_columns) { %w[number title assignees created_at] }
  let(:view_configuration) do
    instance_double(ViewConfiguration, view_type: 'tickets', available_columns: available, ordered_columns: base_columns,
                                       pinned_column_keys: pinned_keys)
  end
  let(:smart_folder) { nil }
  # Which columns stay readable when the width runs out (designer, 07.09.2026).
  # Empty by default: a pin is something the reader sets, never a default.
  let(:pinned_keys) { [] }

  subject(:columns) { described_class.call(view_configuration: view_configuration, smart_folder: smart_folder) }

  def keys = columns.map { |c| c[:key] }
  def ranks = columns.map { |c| c[:rank] }

  it 'answers the base view in its saved order, ranks beyond number and title' do
    expect(keys).to eq(%w[number title assignees created_at])
    expect(ranks).to eq([nil, nil, 1, 2])
  end

  it 'keeps the available column hash and adds rank and min_width' do
    assignees = columns.find { |c| c[:key] == 'assignees' }
    expect(assignees).to include(label: 'Zugewiesen', type: 'users', rank: 1, min_width: 120)
  end

  context 'with a folder that has its own list' do
    let(:smart_folder) { instance_double(SmartFolder, ordered_columns: %w[number title created_at tags], pinned_column_keys: []) }

    it 'takes the folder over the base view' do
      expect(keys).to eq(%w[number title created_at tags])
      expect(ranks.last(2)).to eq([1, 2])
    end
  end

  context 'with a folder that follows the base view (no list of its own)' do
    let(:smart_folder) { instance_double(SmartFolder, ordered_columns: nil, pinned_column_keys: nil) }

    it 'falls back to the base view' do
      expect(keys).to eq(base_columns)
    end
  end

  it 'drops a key the reader may not see and re-ranks the rest' do
    folder = instance_double(SmartFolder, ordered_columns: %w[number title time_spent tags nope assignees], pinned_column_keys: [])
    expect(described_class.call(view_configuration: view_configuration, smart_folder: folder).map { |c| [c[:key], c[:rank]] })
      .to eq([['number', nil], ['title', nil], ['tags', 1], ['assignees', 2]])
  end

  describe 'min_width' do
    let(:smart_folder) { instance_double(SmartFolder, ordered_columns: %w[number title assignees custom_status custom_color], pinned_column_keys: []) }

    it 'comes from the key, then the type, then the default' do
      widths = columns.to_h { |c| [c[:key], c[:min_width]] }
      # number is 48 because the stylesheet says 48, and title is 320 because
      # that is how much of a headline a reader gets before any other column
      # gets anything (07.09.2026). Both read from the constant, not typed.
      expect(widths).to include('number' => ViewConfiguration::COLUMN_MIN_WIDTH_PX['number'],
                                'title' => ViewConfiguration::COLUMN_MIN_WIDTH_PX['title'],
                                'assignees' => 120, 'custom_status' => 138,
                                'custom_color' => ViewConfiguration::DEFAULT_COLUMN_MIN_WIDTH_PX)
    end
  end
  # The status column's minimum (designer, 09.09.2026): a select's 110 cut
  # "In Bearbeitung" while the title had room; the project's status column,
  # keyed custom_status, gets 138. Another select keeps the type's 110.
  describe '.column_min_width for the status column' do
    it 'gives custom_status 138 and any other select its type minimum' do
      expect(ViewConfiguration.column_min_width(key: 'custom_status', type: 'select')).to eq(138)
      expect(ViewConfiguration.column_min_width(key: 'custom_priority', type: 'select')).to eq(110)
    end
  end
end
