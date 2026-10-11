# frozen_string_literal: true

# Server-side desktop/mobile switch for list pages that have their own
# mobile variant (Tickets, Knowledge). The associated Stimulus controller
# (viewport_controller.js) reloads the page below the breakpoint with
# ?viewport=mobile.
module ViewportSwitchable
  extend ActiveSupport::Concern

  VIEWPORT_MODES = %w[desktop mobile].freeze

  private

  def set_viewport_mode
    @viewport_mode = if params[:viewport].present? && VIEWPORT_MODES.include?(params[:viewport])
                       params[:viewport]
                     else
                       'desktop'
                     end
  end
end
