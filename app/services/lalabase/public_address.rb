# frozen_string_literal: true

require 'ipaddr'
require 'socket'

# Does a host reach the public internet, or the network the app server sits in? The
# one owner of that question for every address a customer types and the app then
# connects to with a credential attached: the own AI endpoint (Actors::SaveAiConfiguration
# at save time, Lalabase::Llm::PublicEndpointAdapter for every request).
#
# ⚠️ THE ONE RULE: judge the ADDRESSES a resolver returns, never the characters the
# customer typed. Every earlier version broke on that confusion: IPv4-mapped IPv6
# literals, numeric notations IPAddr refuses but getaddrinfo resolves (127.1,
# 2130706433, 0x7f.0.0.1), then names: `localhost.` with its trailing dot, short names
# of the server network (`redis.`), and public names whose record points inward (a
# CNAME to 127.0.0.1 or to the cloud metadata address). Asking the resolver answers all
# of them at once, and the next notation as well.
#
# A name that does not resolve is refused with the same answer as one that points
# inward. A different answer would tell the caller which internal names exist.
#
# Entry point: resolve!
module Lalabase
  module PublicAddress
    class NotPublicError < StandardError; end

    # Ranges that reach an internal network but that NO IPAddr predicate reports:
    # #loopback?, #private? and #link_local? together do not cover them.
    #
    #   100.64.0.0/10  Carrier-grade NAT (RFC 6598). The address space Tailscale hands
    #                  out, and where several managed-Kubernetes offerings put pod and
    #                  service networks.
    BLOCKED_RANGES = ['100.64.0.0/10'].map { |cidr| IPAddr.new(cidr) }.freeze

    # timeout nil means the system resolver's own limits.
    DEFAULT_RESOLVER = lambda do |hostname, timeout: nil|
      Addrinfo.getaddrinfo(hostname, nil, nil, :STREAM, timeout: timeout).map(&:ip_address).uniq
    end

    class << self
      # Specs replace the resolver (spec/support/public_address_resolver.rb); nil
      # restores the system one.
      attr_writer :resolver

      def resolver
        @resolver || DEFAULT_RESOLVER
      end

      # @param timeout [Numeric, nil] seconds the lookup may take. A lookup that runs
      #   out of time is a name that does not resolve.
      # @return [Array<String>] every address the host resolves to, all of them public
      # @raise [NotPublicError] when the host is blank, does not resolve, or any one of
      #   its addresses is not public
      def resolve!(hostname, timeout: nil)
        host = hostname.to_s.delete_prefix('[').delete_suffix(']')
        raise NotPublicError, 'blank host' if host.empty?

        addresses = addresses_of(host, timeout)
        raise NotPublicError, "#{host} does not resolve" if addresses.empty?
        raise NotPublicError, "#{host} is not a public address" unless addresses.all? { |a| public_ip?(a) }

        addresses
      end

      def public?(hostname, timeout: nil)
        resolve!(hostname, timeout: timeout)
        true
      rescue NotPublicError
        false
      end

      private

      # A literal is its own answer; everything else, including the numeric notations
      # IPAddr does not speak, goes to the resolver.
      def addresses_of(host, timeout)
        [IPAddr.new(host).to_s]
      rescue IPAddr::InvalidAddressError
        resolved_addresses(host, timeout)
      end

      def resolved_addresses(host, timeout)
        Array(resolver.call(host, timeout: timeout))
      rescue SocketError, SystemCallError, IO::TimeoutError
        []
      end

      def public_ip?(text)
        # .native folds ::ffff:7f00:1 back to 127.0.0.1 before any predicate is asked.
        address = IPAddr.new(text.to_s).native

        # The unspecified addresses (0.0.0.0 and ::) are none of the predicates below
        # and mean "this host" to a connecting socket.
        return false if address.to_i.zero?
        return false if BLOCKED_RANGES.any? { |range| range.include?(address) }

        !(address.loopback? || address.private? || address.link_local?)
      rescue IPAddr::InvalidAddressError
        false
      end
    end
  end
end
