# frozen_string_literal: true

# A finger that swipes across the page, for browser specs of a phone.
#
# It sends the touch events one by one (Input.dispatchTouchEvent): touchstart, a row
# of touchmoves, touchend. They go through the browser's own input path, so the browser
# pans what a finger would pan and fires what a finger would fire.
#
# ⚠️ Not Input.synthesizeScrollGesture. On the CI runner (Chrome 156, Linux) that
# gesture arrives as a press and thirty-odd pointermoves, without a single touchmove,
# and nothing scrolls; on a Mac (Chrome 157) it pans as asked. Measured 2026-11-12 with
# listeners on the row: CI `touchstart 1, pointermove 32, pointerup 1, touchend 1`, Mac
# `touchstart 1, touchmove 21, pointercancel 1, scroll 15`. Two specs used it:
#   - management_phone_spec expected the swiped row at its start and was red in CI from
#     the day it was written (2026-11-11);
#   - mobile_shell_regressions_spec expected a locked page NOT to move, which a swipe
#     that moves nothing proves on any page: green in CI without a lock.
# A swipe that must NOT move something therefore shows first, in the same example, that
# it does move the page while nothing holds it.
#
# The finger rests a moment before it lifts, so the page does not coast on after the
# swipe (a fling would still be moving when the example measures).
#
# Touch emulation stays on after the swipe, as it did with the gesture: an example that
# swipes switches it off in its `after` (the browser outlives the example).
module TouchSwipe
  # from, to: { x:, y: } in CSS pixels of the viewport.
  def touch_swipe(from:, to:, steps: 10)
    browser = page.driver.browser
    browser.execute_cdp('Emulation.setTouchEmulationEnabled', enabled: true, maxTouchPoints: 1)
    browser.execute_cdp('Input.dispatchTouchEvent', type: 'touchStart', touchPoints: [from])
    (1..steps).each do |step|
      point = { x: from[:x] + ((to[:x] - from[:x]) * step / steps), y: from[:y] + ((to[:y] - from[:y]) * step / steps) }
      browser.execute_cdp('Input.dispatchTouchEvent', type: 'touchMove', touchPoints: [point])
    end
    sleep 0.15
    browser.execute_cdp('Input.dispatchTouchEvent', type: 'touchMove', touchPoints: [to])
    browser.execute_cdp('Input.dispatchTouchEvent', type: 'touchEnd', touchPoints: [])
    # Two animation frames: what the swipe moved is laid out and reported.
    page.evaluate_async_script('requestAnimationFrame(() => requestAnimationFrame(arguments[0]))')
  end
end

RSpec.configure do |config|
  config.include TouchSwipe, type: :system
end
