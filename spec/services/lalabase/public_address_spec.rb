# frozen_string_literal: true

# What: Unit spec for Lalabase::PublicAddress, the one owner of "does this host reach
#   the public internet?" for an address a customer types.
# Why: the first version of the rule judged the characters in the field. Names with a
#   trailing dot (localhost.), short names of the server network (redis.) and public
#   names whose record points inward (a CNAME to 127.0.0.1 or to the cloud metadata
#   address) all passed it, and the connection test then reported which ports were
#   open. Every case below is decided on the addresses a resolver returns.

require 'rails_helper'

RSpec.describe Lalabase::PublicAddress, :ci_guard do
  describe '.resolve!' do
    it 'returns the addresses of a public name' do
      resolve_names('api.provider.example' => ['52.1.2.3', '2606:4700:4700::1111'])

      expect(described_class.resolve!('api.provider.example')).to eq(['52.1.2.3', '2606:4700:4700::1111'])
    end

    it 'returns a public literal unchanged' do
      expect(described_class.resolve!('52.1.2.3')).to eq(['52.1.2.3'])
    end

    {
      'localhost.' => 'the trailing dot names the same host',
      'LOCALHOST' => 'case does not change a name',
      'redis.' => 'a short name of the server network',
      'localhost.attacker.example' => 'a public name whose record points at loopback',
      'awsmeta.attacker.example' => 'a public name whose record points at the metadata service',
      'cgnat.attacker.example' => 'carrier-grade NAT, which no IPAddr predicate reports',
      'mixed.attacker.example' => 'one inward address among public ones is enough'
    }.each do |hostname, why|
      it "refuses #{hostname} (#{why})" do
        resolve_names(
          'redis' => ['192.168.0.1'],
          'localhost.attacker.example' => ['127.0.0.1', '::1'],
          'awsmeta.attacker.example' => ['169.254.169.254'],
          'cgnat.attacker.example' => ['100.64.0.1'],
          'mixed.attacker.example' => ['52.1.2.3', '192.168.0.1']
        )

        expect { described_class.resolve!(hostname) }.to raise_error(described_class::NotPublicError)
      end
    end

    ['127.0.0.1', '::1', '10.0.0.5', '172.16.0.1', '192.168.0.1', '169.254.169.254',
     '100.64.0.1', '0.0.0.0', '::', '::ffff:127.0.0.1', 'fd00::1', 'fe80::1',
     '127.1', '2130706433', '0x7f.0.0.1', '0xa.0.0.5'].each do |literal|
      it "refuses the literal #{literal}" do
        expect { described_class.resolve!(literal) }.to raise_error(described_class::NotPublicError)
      end
    end

    # Unresolvable and inward must read the same: a different answer for a name that
    # does not exist would tell the caller which internal names do.
    it 'refuses a name that does not resolve' do
      described_class.resolver = ->(_hostname, **) { raise SocketError, 'getaddrinfo: nodename nor servname provided' }

      expect { described_class.resolve!('nowhere.example') }.to raise_error(described_class::NotPublicError)
    end

    it 'refuses a name that resolves to nothing' do
      described_class.resolver = ->(_hostname, **) { [] }

      expect { described_class.resolve!('empty.example') }.to raise_error(described_class::NotPublicError)
    end

    it 'refuses a blank host' do
      expect { described_class.resolve!('') }.to raise_error(described_class::NotPublicError)
    end
  end

  describe '.public?' do
    it 'is true for a public name and false for one that points inward' do
      resolve_names('public.example' => ['52.1.2.3'], 'inward.example' => ['127.0.0.1'])

      expect(described_class.public?('public.example')).to be(true)
      expect(described_class.public?('inward.example')).to be(false)
    end
  end
end
