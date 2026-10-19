# frozen_string_literal: true

require 'faraday/net_http'

# The Faraday adapter for an AI endpoint a customer typed (OpenAiCompatibleProvider
# with operator_endpoint false). It closes what a check at save time cannot: DNS
# answers again for every request, and a name that pointed outward when it was saved
# can point at the app server when the decrypted key is sent (DNS rebinding).
#
# So for every connection it resolves the host through Lalabase::PublicAddress, refuses
# unless every address is public, and pins the socket to the first of them
# (Net::HTTP#ipaddr=). Net::HTTP keeps the NAME for SNI and the certificate check, so
# TLS still verifies the host the customer named.
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

      def net_http_connection(env)
        raise EndpointNotPublicError, 'the endpoint is not a public address' if env[:request][:proxy]

        address = PublicAddress.resolve!(env[:url].hostname).first
        super.tap { |http| http.ipaddr = address }
      rescue PublicAddress::NotPublicError
        raise EndpointNotPublicError, 'the endpoint is not a public address'
      end
    end
  end
end
