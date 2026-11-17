# frozen_string_literal: true

# The inbox above the organisations redraws its counts by itself right after it
# shows: once when its controller connects and again when its cable subscription
# does (all_inboxes_live_controller.js, broadcasts are not replayed). The answer
# replaces the list tools, the organisation select among them, and the sidebar. A
# spec that picks an organisation in that moment works on a select that is gone a
# frame later, and its choice is lost (red on the CI runner, 2026-11-14 to
# 2026-11-16, never on a Mac). The controller sets aria-busy while a redraw is on
# its way.
module InboxLiveHelpers
  LIVE = '[data-controller~="all-inboxes-live"]'

  # Waits until the page listens for its signal and no redraw is on its way.
  def wait_for_inbox_live_at_rest
    expect(page).to have_css("#{LIVE} turbo-cable-stream-source[connected]", visible: :all)
    expect(page).to have_no_css("#{LIVE}[aria-busy]", visible: :all)
  end
end

RSpec.configure do |config|
  config.include InboxLiveHelpers, type: :system
end
