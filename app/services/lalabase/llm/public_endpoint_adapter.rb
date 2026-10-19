# frozen_string_literal: true

require 'faraday/net_http'

# The Faraday adapter for an AI endpoint a customer typed (OpenAiCompatibleProvider
# with operator_endpoint false). It closes what a check at save time cannot: DNS
# answers again for every request, and a name that pointed outward when it was saved
# can point at the app server when the decrypted key is sent (DNS rebinding).
#
# So for every connection it resolves the host through Lalabase::PublicAddress, refuses
# unless every address is public, and connects only to those addresses
# (CheckedAddresses). Net::HTTP keeps the NAME for SNI and the certificate check, so
# TLS still verifies the host the customer named.
#
# Through a proxy the proxy resolves the name and the checked addresses mean nothing,
# so a proxied request is refused. An operator who needs one configures the endpoint
# on a system credential, which does not use this adapter.
#
# Entry point: Faraday calls it (connection.adapter(PublicEndpointAdapter))
module Lalabase
  module Llm
    class PublicEndpointAdapter < Faraday::Adapter::NetHttp
      # A connection failure to every rescue that already handles one (the providers,
      # retry_on in the jobs, ConnectionCheck), with no port or reason in its text.
      class EndpointNotPublicError < Faraday::ConnectionFailed; end

      # The seam below is private to Net::HTTP. Without it Net::HTTP would resolve and
      # connect to the name itself, unchecked, so the adapter refuses to load instead.
      SEAM_MISSING = 'PublicEndpointAdapter needs Net::HTTP#timeouted_connect (net-http >= 0.9, see Gemfile)'
      raise LoadError, SEAM_MISSING unless Net::HTTP.private_method_defined?(:timeouted_connect)

      # Mixed into the one Net::HTTP object of a connection. It takes over
      # Net::HTTP#timeouted_connect, which opens the TCP socket and nothing else, and
      # keeps what Net::HTTP did with a name:
      #
      #   * ONE open timeout for everything up to the open socket, the DNS lookup
      #     included. The lookup runs here, inside it, and not before Net::HTTP starts.
      #   * a race across the addresses (Lalabase::Llm::AddressRace), so an address that
      #     drops packets does not use up the timeout before the next one is tried.
      #   * TLS afterwards, with its own open timeout, exactly as before.
      #
      # Nothing has been written when this returns or fails, so a request is never sent
      # twice.
      module CheckedAddresses
        attr_accessor :checked_host

        private

        def timeouted_connect(_conn_addr, conn_port)
          deadline = open_timeout && (monotonic_now + open_timeout)
          addresses = PublicAddress.resolve!(checked_host, timeout: open_timeout)
          AddressRace.call(addresses: addresses, port: conn_port, deadline: deadline)
        rescue PublicAddress::NotPublicError
          raise EndpointNotPublicError, 'the endpoint is not a public address'
        end

        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      def net_http_connection(env)
        raise EndpointNotPublicError, 'the endpoint is not a public address' if env[:request][:proxy]

        super.tap do |http|
          http.extend(CheckedAddresses)
          http.checked_host = env[:url].hostname
        end
      end
    end
  end
end
