# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SystemFunctions::Registry do
  describe 'Constants' do
    it 'defines all 8 function keys' do
      expect(described_class::ALL_FUNCTIONS).to contain_exactly(
        'is_backlog', 'is_new', 'is_open', 'is_in_progress', 'is_completed', 'is_closed',
        'high_priority', 'highlight_container'
      )
    end

    it 'has frozen ALL_FUNCTIONS array' do
      expect(described_class::ALL_FUNCTIONS).to be_frozen
    end

    it 'has frozen FUNCTION_CATEGORIES hash' do
      expect(described_class::FUNCTION_CATEGORIES).to be_frozen
    end

    it 'defines 3 categories' do
      expect(described_class::FUNCTION_CATEGORIES.keys).to contain_exactly('status', 'priority', 'display')
    end
  end

  describe '.valid?' do
    it 'returns true for known keys' do
      described_class::ALL_FUNCTIONS.each do |key|
        expect(described_class.valid?(key)).to be true
      end
    end

    it 'returns true for symbol keys' do
      expect(described_class.valid?(:is_new)).to be true
    end

    it 'returns false for unknown keys' do
      expect(described_class.valid?('nonexistent')).to be false
      expect(described_class.valid?('')).to be false
    end
  end

  describe '.label_for' do
    it 'returns German label by default' do
      expect(described_class.label_for('is_backlog', :de)).to eq('Backlog')
      expect(described_class.label_for('is_new', :de)).to eq('Neu')
      expect(described_class.label_for('is_open', :de)).to eq('Offen')
      expect(described_class.label_for('high_priority', :de)).to eq('Hohe Priorität')
    end

    it 'returns English label' do
      expect(described_class.label_for('is_new', :en)).to eq('New')
      expect(described_class.label_for('is_open', :en)).to eq('Open')
      expect(described_class.label_for('high_priority', :en)).to eq('High Priority')
    end

    it 'returns nil for unknown key' do
      expect(described_class.label_for('nonexistent')).to be_nil
    end
  end

  describe '.icon_for' do
    it 'returns icon for known key' do
      expect(described_class.icon_for('is_new')).to eq('star')
      expect(described_class.icon_for('is_completed')).to eq('check-circle')
    end

    it 'returns nil for unknown key' do
      expect(described_class.icon_for('nonexistent')).to be_nil
    end
  end

  describe '.category_for' do
    it 'returns correct category for status functions' do
      expect(described_class.category_for('is_backlog')).to eq('status')
      expect(described_class.category_for('is_new')).to eq('status')
      expect(described_class.category_for('is_open')).to eq('status')
      expect(described_class.category_for('is_in_progress')).to eq('status')
      expect(described_class.category_for('is_completed')).to eq('status')
      expect(described_class.category_for('is_closed')).to eq('status')
    end

    it 'returns correct category for priority functions' do
      expect(described_class.category_for('high_priority')).to eq('priority')
    end

    it 'returns correct category for display functions' do
      expect(described_class.category_for('highlight_container')).to eq('display')
    end

    it 'returns nil for unknown key' do
      expect(described_class.category_for('nonexistent')).to be_nil
    end
  end
end
