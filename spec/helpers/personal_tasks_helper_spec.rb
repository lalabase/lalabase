# frozen_string_literal: true

require 'rails_helper'

# Locks the priority-flag behaviour (§16): the flag cycles none -> medium -> high
# -> none, `low` is folded into medium (it has no visible state), and only
# medium/high render a filled, coloured flag. The helpers only read #priority, so
# we feed a verified double — pure logic, no DB / no tenant.
RSpec.describe PersonalTasksHelper, type: :helper do
  def task_with(priority)
    instance_double(PersonalTask, priority: priority)
  end

  describe '#personal_task_next_priority' do
    {
      nil => 'medium',   # none -> medium (skip the invisible "low")
      'low' => 'medium', # legacy/edge low folds forward to medium
      'medium' => 'high',
      'high' => '' # high -> clear (controller maps blank -> nil)
    }.each do |current, expected|
      it "cycles #{current.inspect} -> #{expected.inspect}" do
        expect(helper.personal_task_next_priority(task_with(current))).to eq(expected)
      end
    end
  end

  describe '#personal_task_priority_filled?' do
    it 'is true only for medium and high (the visible states)' do
      expect(helper.personal_task_priority_filled?(task_with('medium'))).to be(true)
      expect(helper.personal_task_priority_filled?(task_with('high'))).to be(true)
      expect(helper.personal_task_priority_filled?(task_with('low'))).to be(false)
      expect(helper.personal_task_priority_filled?(task_with(nil))).to be(false)
    end
  end

  describe '#personal_task_priority_classes' do
    it 'maps high=red, medium=amber, everything else=muted (never lime)' do
      expect(helper.personal_task_priority_classes(task_with('high'))).to eq('text-red-500')
      expect(helper.personal_task_priority_classes(task_with('medium'))).to eq('text-amber-500')
      expect(helper.personal_task_priority_classes(task_with('low'))).to eq('text-cream-400')
      expect(helper.personal_task_priority_classes(task_with(nil))).to eq('text-cream-400')
    end
  end

  describe '#personal_task_row_button_class' do
    it 'prepends the shared geometry to the per-control colour' do
      result = helper.personal_task_row_button_class('text-red-600')
      expect(result).to start_with('w-9 h-9 flex')
      expect(result).to end_with('text-red-600')
    end
  end
end
