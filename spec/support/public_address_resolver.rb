# frozen_string_literal: true

# Lalabase::PublicAddress resolves every host name it judges. A spec must not depend
# on the DNS of the machine it runs on, so names resolve from a table here:
#
#   * a numeric notation (127.1, 2130706433, 0x7f.0.0.1) goes to the real resolver
#     with AI_NUMERICHOST, which answers without the network, exactly as production
#     would;
#   * a name in the table gets the addresses listed there;
#   * any other name resolves to one public address from TEST-NET-3 (RFC 5737), so
#     the endpoints in the factories and specs (api.mistral.ai, sovereign.eu) keep
#     passing without a lookup.
#
# A spec that needs a name to point somewhere else says so:
#   resolve_names('localhost.attacker.example' => ['127.0.0.1', '::1'])
module PublicAddressResolverHelpers
  DEFAULT_PUBLIC_ADDRESS = '203.0.113.10'

  DEFAULT_TABLE = {
    'localhost' => ['127.0.0.1', '::1'],
    'ip6-localhost' => ['::1']
  }.freeze

  def self.resolver_for(table)
    lambda do |hostname, timeout: nil| # rubocop:disable Lint/UnusedBlockArgument
      numeric = numeric_addresses(hostname)
      next numeric if numeric

      name = hostname.downcase.delete_suffix('.')
      table.fetch(name, [DEFAULT_PUBLIC_ADDRESS])
    end
  end

  def self.numeric_addresses(hostname)
    Addrinfo.getaddrinfo(hostname, nil, nil, :STREAM, nil, Socket::AI_NUMERICHOST).map(&:ip_address).uniq
  rescue SocketError
    nil
  end

  def resolve_names(table)
    Lalabase::PublicAddress.resolver =
      PublicAddressResolverHelpers.resolver_for(DEFAULT_TABLE.merge(table.transform_keys(&:downcase)))
  end
end

RSpec.configure do |config|
  config.include PublicAddressResolverHelpers

  config.before do
    Lalabase::PublicAddress.resolver = PublicAddressResolverHelpers.resolver_for(PublicAddressResolverHelpers::DEFAULT_TABLE)
  end

  config.after { Lalabase::PublicAddress.resolver = nil }
end
