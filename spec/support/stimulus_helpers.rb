# frozen_string_literal: true

# A page shows before its scripts listen. Stimulus loads the controllers as
# modules after the HTML (controllers/index.js, eagerLoadControllersFrom), so
# a click right after a visit can land on a button whose controller is not
# connected yet and do nothing. On a cold browser (the first example of a run)
# that window is long enough to fail most runs.
module StimulusHelpers
  # Waits until the controller `identifier` is connected on the first element
  # matching `selector`.
  def wait_for_stimulus(selector, identifier)
    script = <<~JS
      (() => {
        const element = document.querySelector(#{selector.to_json})
        return Boolean(element && window.Stimulus &&
          window.Stimulus.getControllerForElementAndIdentifier(element, #{identifier.to_json}))
      })()
    JS
    page.document.synchronize do
      raise Capybara::ExpectationNotMet, "#{identifier} is not connected yet" unless page.evaluate_script(script)
    end
  end
end

RSpec.configure do |config|
  config.include StimulusHelpers, type: :system
end
