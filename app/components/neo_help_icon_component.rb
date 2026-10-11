# frozen_string_literal: true

class NeoHelpIconComponent < ViewComponent::Base
  def initialize(context:, actions: [], size: :small, position: :left)
    @context = context
    @actions = actions
    @size = size
    @position = position
  end

  private

  attr_reader :context, :actions, :size, :position

  def icon_classes
    base_classes = 'inline-flex items-center justify-center rounded transition-colors duration-200 cursor-pointer text-gray-400 hover:text-cream-900 focus-visible:text-cream-900 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ink'
    size_classes = case size
                   when :small then 'h-6 px-2'
                   when :medium then 'h-8 px-3'
                   else 'h-8 px-3'
                   end
    "#{base_classes} #{size_classes}"
  end

  def help_content_grouped
    # Define groups and their actions
    groups = {
      viewing: %w[activity_timeline time_tracking],
      notifications: ['notifications_toggle'],
      editing: %w[edit move_ticket]
    }

    # Build grouped content
    groups.map do |group_key, group_actions|
      # Only include actions that are in the provided actions list
      relevant_actions = group_actions & actions

      next if relevant_actions.empty?

      {
        key: group_key,
        title: t("#{context}_help.groups.#{group_key}", default: group_key.to_s.humanize),
        actions: relevant_actions.map do |action|
          {
            key: action,
            icon: t("#{context}_help.buttons.#{action}.icon", default: 'question-circle'),
            title: t("#{context}_help.buttons.#{action}.title"),
            description: t("#{context}_help.buttons.#{action}.description"),
            keyboard_shortcut: t("#{context}_help.buttons.#{action}.shortcut", default: nil)
          }
        end
      }
    end.compact
  end

  def help_content
    # Keep for backwards compatibility
    actions.map do |action|
      {
        key: action,
        icon: t("#{context}_help.buttons.#{action}.icon", default: 'question-circle'),
        title: t("#{context}_help.buttons.#{action}.title"),
        description: t("#{context}_help.buttons.#{action}.description"),
        keyboard_shortcut: t("#{context}_help.buttons.#{action}.shortcut", default: nil)
      }
    end
  end

  def modal_id
    "help-modal-#{context}"
  end
end
