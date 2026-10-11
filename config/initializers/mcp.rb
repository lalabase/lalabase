# frozen_string_literal: true

# The mcp gem turns an exception raised inside a tool call into a JSON-RPC
# internal error (-32603) and hands the exception to this reporter, whose
# default is a no-op lambda. Api::McpController then renders that error body
# with HTTP 200, so neither Rails' exception middleware nor the request log ever
# sees it: without this hook an internal error on the MCP surface (a bug in a
# tool, the D7 tripwire, a database error) leaves no server-side trace at all.
MCP.configure do |config|
  config.exception_reporter = lambda do |exception, server_context|
    Rails.error.report(exception, handled: true, severity: :error, source: 'mcp',
                                  context: server_context.to_h)
  end
end
