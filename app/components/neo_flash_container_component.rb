# frozen_string_literal: true

# Component to render all flash messages at once
class NeoFlashContainerComponent < ViewComponent::Base
  def initialize(flash:, **options)
    @flash = flash
    @options = options
  end
end
