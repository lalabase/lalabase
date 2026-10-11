# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TicketColorMap do
  describe '.status_dot_color' do
    it 'returns cobalt for open statuses' do
      %w[offen open neu new].each do |status|
        expect(described_class.status_dot_color(status)).to eq('bg-cobalt-500'), "Expected cobalt for '#{status}'"
      end
    end

    it 'returns amber for in-progress statuses' do
      ['in bearbeitung', 'in arbeit', 'in progress', 'bearbeitung'].each do |status|
        expect(described_class.status_dot_color(status)).to eq('bg-amber-500'), "Expected amber for '#{status}'"
      end
    end

    it 'returns green for done statuses' do
      %w[erledigt fertig done abgeschlossen].each do |status|
        expect(described_class.status_dot_color(status)).to eq('bg-green-500'), "Expected green for '#{status}'"
      end
    end

    it 'returns cream for closed statuses' do
      %w[geschlossen closed].each do |status|
        expect(described_class.status_dot_color(status)).to eq('bg-cream-500'), "Expected cream for '#{status}'"
      end
    end

    it 'returns default color for unknown status' do
      expect(described_class.status_dot_color('unknown')).to eq('bg-cream-400')
    end

    it 'is case-insensitive' do
      expect(described_class.status_dot_color('OPEN')).to eq('bg-cobalt-500')
      expect(described_class.status_dot_color('Done')).to eq('bg-green-500')
      expect(described_class.status_dot_color('IN PROGRESS')).to eq('bg-amber-500')
      expect(described_class.status_dot_color('Geschlossen')).to eq('bg-cream-500')
    end

    it 'handles nil safely' do
      expect(described_class.status_dot_color(nil)).to eq('bg-cream-400')
    end

    it 'handles empty string' do
      expect(described_class.status_dot_color('')).to eq('bg-cream-400')
    end

    it 'handles whitespace-only string' do
      expect(described_class.status_dot_color('  ')).to eq('bg-cream-400')
    end

    it 'handles numeric input' do
      expect(described_class.status_dot_color(42)).to eq('bg-cream-400')
    end

    it 'handles symbol input' do
      expect(described_class.status_dot_color(:open)).to eq('bg-cobalt-500')
    end
  end

  describe '.priority_dot_color' do
    it 'returns red for high priorities' do
      %w[hoch high dringend urgent critical kritisch].each do |prio|
        expect(described_class.priority_dot_color(prio)).to eq('bg-red-500'), "Expected red for '#{prio}'"
      end
    end

    it 'returns amber for medium priorities' do
      %w[mittel medium normal].each do |prio|
        expect(described_class.priority_dot_color(prio)).to eq('bg-amber-500'), "Expected amber for '#{prio}'"
      end
    end

    it 'returns cobalt for low priorities' do
      %w[niedrig low gering].each do |prio|
        expect(described_class.priority_dot_color(prio)).to eq('bg-cobalt-500'), "Expected cobalt for '#{prio}'"
      end
    end

    it 'returns default color for unknown priority' do
      expect(described_class.priority_dot_color('unknown')).to eq('bg-cream-400')
    end

    it 'is case-insensitive' do
      expect(described_class.priority_dot_color('HIGH')).to eq('bg-red-500')
      expect(described_class.priority_dot_color('Medium')).to eq('bg-amber-500')
      expect(described_class.priority_dot_color('LOW')).to eq('bg-cobalt-500')
    end

    it 'handles nil safely' do
      expect(described_class.priority_dot_color(nil)).to eq('bg-cream-400')
    end

    it 'handles empty string' do
      expect(described_class.priority_dot_color('')).to eq('bg-cream-400')
    end

    it 'handles symbol input' do
      expect(described_class.priority_dot_color(:high)).to eq('bg-red-500')
    end
  end

  describe '.dot_color_for_function' do
    it 'returns lime for IS_NEW' do
      expect(described_class.dot_color_for_function(SystemFunctions::Registry::IS_NEW)).to eq('bg-cobalt-500')
    end

    it 'returns yellow for IS_IN_PROGRESS' do
      expect(described_class.dot_color_for_function(SystemFunctions::Registry::IS_IN_PROGRESS)).to eq('bg-amber-500')
    end

    it 'returns green for IS_COMPLETED' do
      expect(described_class.dot_color_for_function(SystemFunctions::Registry::IS_COMPLETED)).to eq('bg-green-500')
    end

    it 'returns gray for IS_CLOSED' do
      expect(described_class.dot_color_for_function(SystemFunctions::Registry::IS_CLOSED)).to eq('bg-cream-500')
    end

    it 'returns red for HIGH_PRIORITY' do
      expect(described_class.dot_color_for_function(SystemFunctions::Registry::HIGH_PRIORITY)).to eq('bg-red-500')
    end

    it 'returns default color for unknown function key' do
      expect(described_class.dot_color_for_function('nonexistent_function')).to eq('bg-cream-400')
    end

    it 'handles nil safely' do
      expect(described_class.dot_color_for_function(nil)).to eq('bg-cream-400')
    end

    it 'handles symbol input by converting to string' do
      expect(described_class.dot_color_for_function(:is_new)).to eq('bg-cobalt-500')
    end
  end

  describe '.badge_color_for_function' do
    it 'returns badge colors for IS_NEW' do
      expect(described_class.badge_color_for_function(SystemFunctions::Registry::IS_NEW)).to eq('bg-cobalt-100 text-cobalt-900')
    end

    it 'returns badge colors for IS_IN_PROGRESS' do
      expect(described_class.badge_color_for_function(SystemFunctions::Registry::IS_IN_PROGRESS)).to eq('bg-amber-100 text-amber-900')
    end

    it 'returns badge colors for IS_COMPLETED' do
      expect(described_class.badge_color_for_function(SystemFunctions::Registry::IS_COMPLETED)).to eq('bg-green-100 text-green-900')
    end

    it 'returns badge colors for IS_CLOSED' do
      expect(described_class.badge_color_for_function(SystemFunctions::Registry::IS_CLOSED)).to eq('bg-cream-200 text-cream-600')
    end

    it 'returns badge colors for HIGH_PRIORITY' do
      expect(described_class.badge_color_for_function(SystemFunctions::Registry::HIGH_PRIORITY)).to eq('bg-red-100 text-red-900')
    end

    it 'returns default badge color for unknown function key' do
      expect(described_class.badge_color_for_function('nonexistent_function')).to eq(described_class::DEFAULT_BADGE_COLOR)
    end

    it 'handles nil safely' do
      expect(described_class.badge_color_for_function(nil)).to eq(described_class::DEFAULT_BADGE_COLOR)
    end

    it 'handles symbol input by converting to string' do
      expect(described_class.badge_color_for_function(:is_new)).to eq('bg-cobalt-100 text-cobalt-900')
    end
  end

  describe '.priority_badge_color' do
    it 'returns red badge for high priorities' do
      expected = 'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200'
      %w[hoch high dringend urgent critical kritisch].each do |prio|
        expect(described_class.priority_badge_color(prio)).to eq(expected), "Expected red badge for '#{prio}'"
      end
    end

    it 'returns amber badge for medium priorities' do
      expected = 'bg-amber-100 text-amber-900'
      %w[mittel medium normal].each do |prio|
        expect(described_class.priority_badge_color(prio)).to eq(expected), "Expected amber badge for '#{prio}'"
      end
    end

    it 'returns cobalt badge for low priorities' do
      expected = 'bg-cobalt-100 text-cobalt-900'
      %w[niedrig low gering].each do |prio|
        expect(described_class.priority_badge_color(prio)).to eq(expected), "Expected cobalt badge for '#{prio}'"
      end
    end

    it 'returns default badge color for unknown priority' do
      expect(described_class.priority_badge_color('unknown')).to eq(described_class::DEFAULT_BADGE_COLOR)
    end

    it 'is case-insensitive' do
      expect(described_class.priority_badge_color('HIGH')).to include('text-red-800')
      expect(described_class.priority_badge_color('Medium')).to include('text-amber-900')
    end

    it 'handles nil safely' do
      expect(described_class.priority_badge_color(nil)).to eq(described_class::DEFAULT_BADGE_COLOR)
    end

    it 'handles empty string' do
      expect(described_class.priority_badge_color('')).to eq(described_class::DEFAULT_BADGE_COLOR)
    end

    it 'handles symbol input' do
      expect(described_class.priority_badge_color(:high)).to include('text-red-800')
    end
  end

  describe 'CLOSED_STATUSES' do
    it 'includes all done and closed statuses' do
      expect(described_class::CLOSED_STATUSES).to include('erledigt', 'fertig', 'done', 'abgeschlossen')
      expect(described_class::CLOSED_STATUSES).to include('geschlossen', 'closed')
    end

    it 'does not include open or in-progress statuses' do
      expect(described_class::CLOSED_STATUSES).not_to include('offen', 'open', 'neu', 'new')
      expect(described_class::CLOSED_STATUSES).not_to include('in bearbeitung', 'in progress')
    end

    it 'is frozen' do
      expect(described_class::CLOSED_STATUSES).to be_frozen
    end
  end

  describe 'constants immutability' do
    it 'freezes STATUS_COLORS' do
      expect(described_class::STATUS_COLORS).to be_frozen
    end

    it 'freezes PRIORITY_COLORS' do
      expect(described_class::PRIORITY_COLORS).to be_frozen
    end

    it 'freezes SYSTEM_FUNCTION_DOT_COLORS' do
      expect(described_class::SYSTEM_FUNCTION_DOT_COLORS).to be_frozen
    end

    it 'freezes SYSTEM_FUNCTION_BADGE_COLORS' do
      expect(described_class::SYSTEM_FUNCTION_BADGE_COLORS).to be_frozen
    end

    it 'freezes PRIORITY_BADGE_COLORS' do
      expect(described_class::PRIORITY_BADGE_COLORS).to be_frozen
    end
  end

  describe 'consistency between color hashes' do
    it 'has matching keys between PRIORITY_COLORS and PRIORITY_BADGE_COLORS' do
      priority_keys = described_class::PRIORITY_COLORS.keys.sort
      badge_keys = described_class::PRIORITY_BADGE_COLORS.keys.sort

      expect(priority_keys).to eq(badge_keys),
                               "PRIORITY_COLORS keys #{priority_keys} differ from PRIORITY_BADGE_COLORS keys #{badge_keys}"
    end

    it 'maps every SYSTEM_FUNCTION_DOT_COLORS key to SYSTEM_FUNCTION_BADGE_COLORS' do
      dot_keys = described_class::SYSTEM_FUNCTION_DOT_COLORS.keys.sort
      badge_keys = described_class::SYSTEM_FUNCTION_BADGE_COLORS.keys.sort

      expect(dot_keys).to eq(badge_keys)
    end
  end
end
