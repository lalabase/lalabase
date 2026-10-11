# frozen_string_literal: true

module Lalabase
  module Tools
    # Records whether a tool performed a per-record Pundit authorization during a
    # single MCP tool call. The ToolCall creates one, passes it into the Context,
    # and — for :record-mode tools — asserts afterwards that the tool actually
    # called Base.authorize! (the D7 runtime tripwire, the MCP analogue of a
    # controller's verify_authorized).
    #
    # Single-use and not thread-shared: a fresh recorder is built per call inside
    # the request, so no synchronization is needed.
    class AuthorizationRecorder
      def initialize
        @authorized = false
      end

      # Marked by Base.authorize! after a successful per-record policy check.
      def record!
        @authorized = true
      end

      def authorized?
        @authorized
      end
    end
  end
end
