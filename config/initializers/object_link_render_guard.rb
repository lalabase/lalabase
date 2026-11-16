# frozen_string_literal: true

# No object chip in a render that is not the page of the signed-in reader
# (ObjectLinksHelper, ObjectLinks::Chips).
#
# A chip writes a title or a name the READER may read. ActionText renders its layout, where
# the chips go in, through the controller of the current request
# (ActionText::Content.with_renderer, set around every action). A Turbo broadcast rendered
# synchronously during that request (ApplicationController.render, through
# ActionController::Renderer) renders rich text through that same controller, would see the
# request's user as the reader, and is received by every subscriber of the stream. This
# guard marks such a render, and the helper renders the plain link while the mark is set.
#
# A mail needs no mark: ActionText sets the MAILER as its renderer around a mailer action,
# and a mailer has no signed-in user. Rendered later from a job, a broadcast has none either.
#
# Defined here rather than under app/ or lib/: it is prepended into framework classes once
# at boot, and a module the reloader replaces would leave the framework holding a stale copy.
# Spec: spec/requests/object_link_chips_render_guard_spec.rb.
module ObjectLinkRenderGuard
  KEY = :object_link_render_guard_suppressed

  def self.suppressed?
    ActiveSupport::IsolatedExecutionState[KEY] == true
  end

  def self.suppress
    previous = ActiveSupport::IsolatedExecutionState[KEY]
    ActiveSupport::IsolatedExecutionState[KEY] = true
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[KEY] = previous
  end

  # ApplicationController.render and every renderer built from it.
  module Renderer
    def render(...)
      ObjectLinkRenderGuard.suppress { super }
    end
  end
end

ActiveSupport.on_load(:action_controller) do
  ActionController::Renderer.prepend(ObjectLinkRenderGuard::Renderer)
end
