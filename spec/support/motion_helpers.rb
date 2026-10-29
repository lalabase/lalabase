# frozen_string_literal: true

# A lane opens beside its list by a transition of the grid's columns (layout.css,
# .layout.two-column: grid-template-columns, 0.25 s), and every control of the list
# column travels with it, up to 100 px a frame. The driver measures where a control is
# and clicks there a moment later: a frame in between, and the click lands beside the
# control, on whatever has moved in. That hit the "+" of both meeting lists (one run in
# ten) and, on the CI runner, the filter button of a project's meetings, whose click
# went into the search field next to it.
module MotionHelpers
  # How long an element has to keep its place and size to count as still, in seconds.
  STILL_FOR = 0.15

  # Waits until the element that `find(selector)` finds (visible, within the current
  # scope: the one a click would hit) has kept its place and size for STILL_FOR seconds.
  def wait_until_still(selector)
    page.document.synchronize do
      element = find(selector)
      before = MotionHelpers.box(element)
      sleep STILL_FOR
      raise Capybara::ExpectationNotMet, "#{selector} is still moving" unless MotionHelpers.box(element) == before
    end
  end

  # A module function, not a helper method: several specs define a `box` of their own.
  def self.box(element)
    element.evaluate_script('(r => [r.left, r.top, r.width, r.height])(this.getBoundingClientRect())')
  end
end

RSpec.configure do |config|
  config.include MotionHelpers, type: :system
end
