# frozen_string_literal: true

# Entry point: Tickets::ResolveColumns.call
# Keeps the existing ticket entry point for the shared column resolver.
module Tickets
  class ResolveColumns < Lists::ResolveColumns
  end
end
