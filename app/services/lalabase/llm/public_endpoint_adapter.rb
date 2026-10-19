# frozen_string_literal: true

require 'faraday/net_http'

# The Faraday adapter for an AI endpoint a customer typed (OpenAiCompatibleProvider
# with operator_endpoint false). It closes what a check at save time cannot: DNS
# answers again for every request, and a name that pointed outward when it was saved
# can point at the app server when the decrypted key is sent (DNS rebinding).
#
# So for every connection it resolves the host through Lalabase::PublicAddress, refuses
# unless every address is public, and connects only to those addresses, in the order
# the resolver gave them (PinnedAddresses). Net::HTTP keeps the NAME for SNI and the
# certificate check, so TLS still verifies the host the customer named.
#
# Through a proxy the proxy resolves the name and the pinned address means nothing, so
# a proxied request is refused. An operator who needs one configures the endpoint on a
# system credential, which does not use this adapter.
#
# Entry point: Faraday calls it (connection.adapter(PublicEndpointAdapter))
module Lalabase
  module Llm
    class PublicEndpointAdapter < Faraday::Adapter::NetHttp
      # A connection failure to every rescue that already handles one (the providers,
      # retry_on in the jobs, ConnectionCheck), with no port or reason in its text.
      class EndpointNotPublicError < Faraday::ConnectionFailed; end

      # Mixed into the one Net::HTTP object of a connection. Given the name, Net::HTTP
      # let TCPSocket try every address of it; given one pinned address, a dual-stack
      # endpoint with broken IPv6 would fail although its IPv4 address answers. So the
      # TCP connect walks the checked addresses in order and gives up with the last
      # error.
      #
      # Only around Net::HTTP#connect, which opens the socket and does the TLS
      # handshake and nothing else: the request is written after it returns, so
      # nothing has been sent when the next address is tried, and a request is never
      # sent twice. On failure #connect closes the socket it opened. #connect is
      # private, but it is the seam both the net-http gem in the bundle (0.6.0) and the
      # one in Ruby 4.0 share; the helper below it differs between the two.
      #
      # All attempts share ONE open timeout, as all addresses of a name did before.
      # Restarting it per address would turn the client's budget (120 seconds from
      # ruby-openai) into one per address, and a worker would hang N times as long on
      # an endpoint that drops packets. Each attempt gets what is left; the configured
      # value is restored afterwards for any later reconnect. Since #connect also does
      # the TLS handshake, the handshake now draws on the same budget: stricter than
      # before, never longer.
      module PinnedAddresses
        CONNECT_ERRORS = [SystemCallError, IO::TimeoutError, Net::OpenTimeout].freeze

        attr_accessor :pinned_addresses

        private

        def connect
          budget = open_timeout
          deadline = budget && (monotonic_now + budget)
          pinned_addresses.each_with_index do |address, index|
            self.ipaddr = address
            self.open_timeout = remaining_until(deadline) if deadline
            return super
          rescue *CONNECT_ERRORS
            raise if index == pinned_addresses.size - 1
          end
        ensure
          self.open_timeout = budget
        end

        def remaining_until(deadline)
          remaining = deadline - monotonic_now
          raise Net::OpenTimeout, 'the open timeout is spent' unless remaining.positive?

          remaining
        end

        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      def net_http_connection(env)
        raise EndpointNotPublicError, 'the endpoint is not a public address' if env[:request][:proxy]

        addresses = PublicAddress.resolve!(env[:url].hostname)
        super.tap do |http|
          http.extend(PinnedAddresses)
          http.pinned_addresses = addresses
          # What Net::HTTP reports as the address it connects to (#ipaddr, and the
          # "Failed to open TCP connection to" message) is the first checked one.
          http.ipaddr = addresses.first
        end
      rescue PublicAddress::NotPublicError
        raise EndpointNotPublicError, 'the endpoint is not a public address'
      end
    end
  end
end
