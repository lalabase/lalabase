# frozen_string_literal: true

# Renders a template the way a reader's own request renders it, without a route: a
# controller of the app with that reader signed in, set as ActionText's renderer the way
# ActionText's around_action does for every request (ActionText::Content.with_renderer).
#
# Needed by the object chip specs for two renders no page offers on its own: the cached
# comment partial (rendered by no page today) and a broadcast that runs INSIDE a reader's
# request (ApplicationController.render while ActionText still renders through the reader's
# controller).
module ObjectLinkRenderHelpers
  def reader_controller(user, host: 'www.example.com')
    controller = ApplicationController.new
    controller.set_request!(ActionDispatch::TestRequest.create('HTTP_HOST' => host))
    controller.set_response!(ActionDispatch::Response.new)
    controller.define_singleton_method(:current_user) { user }
    controller
  end

  # The template rendered by `controller`, with ActionText rendering through it as well.
  def render_as_reader(controller, **options)
    ActionText::Content.with_renderer(controller) do
      controller.render_to_string(**options)
    end
  end
end

RSpec.configure do |config|
  config.include ObjectLinkRenderHelpers, :object_link_render
end
