# frozen_string_literal: true

# The shared "this widget has nothing to show right now" line, used by every overview widget's empty
# branch. Deliberately quiet: no border, no fill, muted text, modest padding — emptiness should recede
# into calm whitespace instead of presenting as a prominent bordered empty box (the old card read as a
# "big empty box" on screen). The widget header above still names the widget, so the slot never looks
# broken. Pairs with [[WidgetHeaderComponent]] as the other half of the shared widget chrome.
class WidgetEmptyComponent < ViewComponent::Base
  def initialize(message:)
    @message = message
  end

  private

  attr_reader :message
end
