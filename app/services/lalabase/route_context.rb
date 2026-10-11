# frozen_string_literal: true

# A routing context for code that builds paths with NO view and NO request: the
# citation links, which are also built inside the streaming broadcast.
#
# ⚠️ A class that INCLUDES, never an object that extends. `routes.url_helpers` is an
# ActiveSupport::Concern and keeps ActionDispatch::Routing::UrlFor as a DEFERRED
# dependency rather than in its own ancestry. `include` runs Concern's append_features
# and pulls that dependency in; `extend` never goes through append_features, so the
# object ends up carrying the generated path methods and NOT the machinery those
# methods call (`optimize_routes_generation?`, `url_options`). Every helper call then
# raises NoMethodError.
#
# That was live for one deploy: the assistant panel answered 500 on every message
# carrying a citation, because CitationLink built its helpers with `Object.new.extend`.
#
# A spec cannot see the difference by calling a helper. The test environment mixes
# UrlFor into Object itself, so a broken context BORROWS the missing methods and looks
# healthy right up until production, where Object carries nothing of the sort.
# Guards: spec/services/lalabase/route_context_spec.rb (names the construction) and
# route_context_boot_spec.rb (leaves the process to reach a bare Object).
#
# Entry point: .new
module Lalabase
  class RouteContext
    include Rails.application.routes.url_helpers
    # The time list address (a report citation opens that list).
    include TimeListHelper
    include AssistantArtefactsHelper
  end
end
