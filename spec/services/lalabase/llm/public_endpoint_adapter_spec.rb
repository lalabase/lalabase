# frozen_string_literal: true

# What: Lalabase::Llm::PublicEndpointAdapter, and the OpenAI-compatible provider that
#   uses it for an endpoint a customer typed.
# Why: a check at save time cannot hold. DNS answers again for every request, and a
#   name that pointed outward when it was saved can point at the app server when the
#   key is sent (DNS rebinding). So the address is judged again for every connection,
#   and the socket goes to exactly the address that was judged, never to a second
#   lookup of the name.

require 'rails_helper'
require 'socket'

RSpec.describe Lalabase::Llm::PublicEndpointAdapter, :ci_guard do
  def env_for(url)
    Faraday::Env.from(method: :get, url: URI(url), request: Faraday::RequestOptions.new,
                      ssl: Faraday::SSLOptions.new, request_headers: {})
  end

  def connection_for(url)
    described_class.new(->(env) { env }).send(:net_http_connection, env_for(url))
  end

  describe 'the connection it builds' do
    it 'connects to the address it checked and keeps the name for TLS' do
      resolve_names('api.provider.example' => ['52.1.2.3'])

      http = connection_for('https://api.provider.example/v1/models')

      expect(http.ipaddr).to eq('52.1.2.3')
      expect(http.address).to eq('api.provider.example')
    end

    it 'refuses a name that points inward' do
      resolve_names('localhost.attacker.example' => ['127.0.0.1'])

      expect { connection_for('https://localhost.attacker.example/v1/models') }
        .to raise_error(described_class::EndpointNotPublicError)
    end

    # Rebinding: the first answer was public (that is what the save saw), the next
    # one is not. The adapter asks again and refuses.
    it 'judges the address again for every connection' do
      answers = [['52.1.2.3'], ['127.0.0.1']]
      Lalabase::PublicAddress.resolver = ->(_hostname) { answers.shift }

      expect(connection_for('https://rebind.attacker.example/v1').ipaddr).to eq('52.1.2.3')
      expect { connection_for('https://rebind.attacker.example/v1') }
        .to raise_error(described_class::EndpointNotPublicError)
    end

    # Through a proxy the proxy resolves the name, and the address checked here would
    # mean nothing.
    it 'refuses to go through a proxy' do
      resolve_names('api.provider.example' => ['52.1.2.3'])
      env = env_for('https://api.provider.example/v1')
      env.request.proxy = { uri: URI('http://proxy.example:3128') }

      expect { described_class.new(->(e) { e }).send(:net_http_connection, env) }
        .to raise_error(described_class::EndpointNotPublicError)
    end

    it 'is a connection failure to every rescue that already handles one' do
      expect(described_class::EndpointNotPublicError.ancestors).to include(Faraday::ConnectionFailed)
    end
  end

  # With the name, Net::HTTP let TCPSocket try every address of it. Pinned to one
  # address, a dual-stack endpoint with broken IPv6 would fail every request although
  # its IPv4 address answers. So the TCP connect walks the checked addresses in order,
  # and only the connect: nothing has been sent at that point, so trying the next
  # address cannot send a request twice.
  describe 'failover across the checked addresses' do
    let(:server) { TCPServer.new('127.0.0.1', 0) }
    let(:attempts) { [] }

    after { server.close }

    def connect_through(unreachable:)
      allow(TCPSocket).to receive(:open).and_wrap_original do |original, address, _port, *rest, **options|
        attempts << address
        raise Errno::ENETUNREACH, address if unreachable.include?(address)

        original.call('127.0.0.1', server.addr[1], *rest, **options)
      end

      http = connection_for("http://dual.provider.example:#{server.addr[1]}/v1")
      http.start(&:started?)
    end

    it 'connects to the next checked address when the first is unreachable' do
      resolve_names('dual.provider.example' => ['2001:db8::1', '203.0.113.20'])

      expect(connect_through(unreachable: ['2001:db8::1'])).to be(true)
      expect(attempts).to eq(['2001:db8::1', '203.0.113.20'])
    end

    it 'tries only the checked addresses and fails with the last error when none answers' do
      resolve_names('dual.provider.example' => ['2001:db8::1', '203.0.113.20'])

      expect { connect_through(unreachable: ['2001:db8::1', '203.0.113.20']) }
        .to raise_error(Errno::ENETUNREACH)
      expect(attempts).to eq(['2001:db8::1', '203.0.113.20'])
    end

    # Once connected, the request may have been written. A failure from there on must
    # not go to the next address: a chat request would run, and be billed, twice.
    it 'does not try the next address when the request fails after the connect' do
      resolve_names('dual.provider.example' => ['203.0.113.20', '203.0.113.21'])
      listener = Thread.new { loop { server.accept.close } }
      allow(TCPSocket).to receive(:open).and_wrap_original do |original, address, _port, *rest, **options|
        attempts << address
        original.call('127.0.0.1', server.addr[1], *rest, **options)
      end

      http = connection_for("http://dual.provider.example:#{server.addr[1]}/v1")
      expect { http.request(Net::HTTP::Post.new('/v1/chat/completions')) }.to raise_error(StandardError)
      expect(attempts).to eq(['203.0.113.20'])
    ensure
      listener&.kill
    end
  end

  # End to end, with the real OpenAI client: a listener on loopback stands for a
  # service on the app server, and a public-looking name resolves to it.
  describe 'Lalabase::Llm::OpenAiCompatibleProvider at request time' do
    let(:server) { TCPServer.new('127.0.0.1', 0) }
    let(:accepted) { Queue.new }
    let(:port) { server.addr[1] }

    before do
      resolve_names('inward.attacker.example' => ['127.0.0.1'])
      @listener = Thread.new do
        loop do
          socket = server.accept
          accepted << true
          socket.close
        end
      end
    end

    after do
      @listener.kill
      server.close
    end

    def provider(endpoint, operator_endpoint:)
      Lalabase::Llm::OpenAiCompatibleProvider.new(api_key: 'sk-customer', uri_base: endpoint,
                                                  chat_model: 'm', operator_endpoint: operator_endpoint)
    end

    it 'never opens a socket to an endpoint a customer typed that points inward' do
      expect { provider("https://inward.attacker.example:#{port}/v1", operator_endpoint: false).connectivity_check }
        .to raise_error(described_class::EndpointNotPublicError)

      sleep 0.2
      expect(accepted).to be_empty
    end

    # The other side: an endpoint the operator configured (a model server next to the
    # app on a self-hosted instance) is not the customer's to choose and stays reachable.
    # A literal, because this path does not ask Lalabase::PublicAddress and so does not
    # see the names the spec resolver knows.
    it 'still connects to an endpoint the operator configured' do
      expect { provider("https://127.0.0.1:#{port}/v1", operator_endpoint: true).connectivity_check }
        .to raise_error(StandardError)

      expect(accepted.pop(timeout: 5)).to be(true)
    end
  end
end
