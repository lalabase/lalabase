# frozen_string_literal: true

module Api
  # MCP (Model Context Protocol) endpoint — POST /api/mcp.
  #
  # One JSON-RPC request per HTTP request, authenticated by a Personal Access
  # Token (Authorization: Bearer lalab_pat_...). STATELESS: no MCP session, no
  # SSE — each request is self-contained, so it runs fine under multi-worker Puma.
  #
  # Unlike Api::V1::BaseController, there is no controller-level Pundit tripwire:
  # authorization happens per tool call inside Mcp::ToolCall (project scope for
  # the M1 read tools; per-record Pundit for write tools in M3).
  class McpController < ActionController::API
    include Api::TokenAuthenticatable # before_action :authenticate_with_token! → 401 on bad token

    after_action :reset_current_attributes

    def handle
      json = Mcp::Dispatcher.new(token: current_token).handle_json(request.raw_post)

      if json.nil?
        head :accepted # a JSON-RPC notification has no response body
      else
        # handle_json already returns a serialized JSON string — render it as-is
        # (render json: would double-encode the string).
        render body: json, content_type: 'application/json'
      end
    end

    private

    def reset_current_attributes
      Current.reset
    end
  end
end
