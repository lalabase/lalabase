# frozen_string_literal: true

# Which header names the client behind a proxy: X-Forwarded-For only.
#
# Rack reads the standard `Forwarded` header first and X-Forwarded-For second, for the
# client's address (req.ip, the key of every Rack::Attack throttle) and for host and
# scheme. The proxies an instance runs behind set X-Forwarded-For (Caddy replaces it,
# nginx appends to it) and pass a `Forwarded` header from the client through untouched.
# With Rack's order a client picked its own address: a new `for=` per request was a new
# throttle bucket per request. Pinned by spec/requests/auth_throttle_spec.rb.
Rack::Request.forwarded_priority = [:x_forwarded]
