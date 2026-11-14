# frozen_string_literal: true

# The assistant's companion panel in a browser spec.
module AssistantPanelHelpers
  # A Turbo visit while the open thread still waits for an answer, returned from
  # once the panel stands as it will stay.
  #
  # The panel is a permanent node: the visit keeps it, composer included. But a
  # thread with an outstanding answer makes the panel fetch its frame again
  # (assistant_panel#resyncIfAwaitingAnswer), and the draft and what it is bound
  # to (a revision, a meeting for tasks) go back into the NEW composer when that
  # frame has loaded. Between the visit and that moment the page shows the old
  # composer, then a new and empty one. A check there passes on the old one, and
  # Enter in the empty one sends nothing: the draft came back a moment later and
  # nothing ran (assistant_ticket_suggestions_spec, red about 1 run in 20 until
  # 13.11.2026). So this waits for the frame's own load, counted from before the
  # visit. The panel's listener sits on the panel and runs first: when the count
  # is up, the draft is back.
  def turbo_visit_awaiting_panel_frame(path)
    page.execute_script(<<~JS, path)
      window.__assistantPanelFrameLoads = 0
      document.addEventListener('turbo:frame-load', event => {
        if (event.target.id === 'assistant_panel_body') window.__assistantPanelFrameLoads += 1
      })
      Turbo.visit(arguments[0])
    JS
    page.document.synchronize do
      loaded = page.evaluate_script('window.__assistantPanelFrameLoads')
      raise Capybara::ExpectationNotMet, 'the assistant panel has not loaded its frame again' unless loaded.to_i >= 1
    end
  end
end

RSpec.configure do |config|
  config.include AssistantPanelHelpers, type: :system
end
