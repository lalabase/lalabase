# frozen_string_literal: true

module PersonalTasksHelper
  # Per the approved drawer spec (§16): the flag cycles none -> medium -> high ->
  # none. `low` exists in the model for completeness but is intentionally not a
  # visible state (it would render identically to "none"), so the UI skips it.
  # An empty string clears the priority (the controller maps blank -> nil).
  PERSONAL_TASK_PRIORITY_CYCLE = {
    nil => 'medium',
    'low' => 'medium',
    'medium' => 'high',
    'high' => ''
  }.freeze

  def personal_task_next_priority(task)
    PERSONAL_TASK_PRIORITY_CYCLE[task.priority]
  end

  # Colour carries meaning but is never the ONLY signal — the flag also gets a
  # title/aria-label. lime is reserved for actions, so status uses amber/red.
  def personal_task_priority_classes(task)
    case task.priority
    when 'high'   then 'text-red-500'
    when 'medium' then 'text-amber-500'
    else 'text-cream-400'
    end
  end

  def personal_task_priority_filled?(task)
    %w[medium high].include?(task.priority)
  end

  # The three small icon controls in a to-do row (toggle / priority / delete)
  # share identical geometry; only the colour + hover differs. Keep the shared
  # part here so the row markup shows just what is DIFFERENT per control.
  def personal_task_row_button_class(colour)
    "w-9 h-9 flex items-center justify-center rounded transition-colors #{colour}"
  end
end
